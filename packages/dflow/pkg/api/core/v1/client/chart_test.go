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
	"net/http"
	"net/http/httptest"

	"github.com/dflow-sh/kube-poc/packages/dflow/cli/settings"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/client"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Client Chart", func() {
	Describe("Chart Errors", DescribeChartErrors)
})

func DescribeChartErrors() {

	var dflowClient *client.Client
	var statusCode int
	var responseBody string

	JustBeforeEach(func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(statusCode)
			fmt.Fprint(w, responseBody)
		}))

		dflowClient = client.New(context.Background(), &settings.Settings{API: srv.URL})
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
			Entry("charts", func() (any, error) {
				return dflowClient.ChartList()
			}),
			Entry("chart show", func() (any, error) {
				return dflowClient.ChartShow("chartname")
			}),
			Entry("chart match", func() (any, error) {
				return dflowClient.ChartMatch("chartprefix")
			}),
		)
	})
}
