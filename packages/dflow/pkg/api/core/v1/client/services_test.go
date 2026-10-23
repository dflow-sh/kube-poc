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
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"

	"github.com/dflow-sh/kube-poc/packages/dflow/cli/settings"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/client"
	apierrors "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Client Services", func() {
	Describe("Services Errors", DescribeServicesErrors)
})

func DescribeServicesErrors() {

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

	Describe("deleting a service", func() {
		Context("with a 404 status code", func() {

			BeforeEach(func() {
				statusCode = 404
			})

			When("returns a valid response", func() {
				It("gets a successful response", func() {
					responseBody = `{
						"errors": [
							{
								"status": 404,
								"title": "service 'srv1' does not exist",
								"details": ""
							}
						]
					}`

					resp, err := dflowClient.ServiceDelete(models.ServiceDeleteRequest{}, "namespace-foo", []string{"srv1"})
					Expect(err).To(HaveOccurred())
					Expect(err).To(Equal(&client.APIError{
						StatusCode: 404,
						Err: &apierrors.ErrorResponse{
							Errors: []apierrors.APIError{
								{
									Status: 404,
									Title:  "service 'srv1' does not exist",
								},
							},
						},
					}))
					Expect(resp).To(Equal(models.ServiceDeleteResponse{}))
				})
			})
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
			Entry("service catalog", func() (any, error) {
				return dflowClient.ServiceCatalog()
			}),
			Entry("service catalog show", func() (any, error) {
				return dflowClient.ServiceCatalogShow("servicename")
			}),
			Entry("service all services", func() (any, error) {
				return dflowClient.AllServices()
			}),
			Entry("service create", func() (any, error) {
				return dflowClient.ServiceCreate(models.ServiceCreateRequest{}, "namespace")
			}),
			Entry("service update", func() (any, error) {
				return dflowClient.ServiceUpdate(models.ServiceUpdateRequest{}, "namespace", "prefix")
			}),
			Entry("service catalog match", func() (any, error) {
				return dflowClient.ServiceCatalogMatch("servicenameprefix")
			}),
			Entry("service bind", func() (any, error) {
				return dflowClient.ServiceBind(models.ServiceBindRequest{}, "namespace", "servicename")
			}),
			Entry("service batch bind", func() (any, error) {
				return dflowClient.ServiceBatchBind(models.ServiceBatchBindRequest{
					AppName:      "testapp",
					ServiceNames: []string{"service1", "service2"},
				}, "namespace", "testapp")
			}),
			Entry("service unbind", func() (any, error) {
				return dflowClient.ServiceUnbind(models.ServiceUnbindRequest{}, "namespace", "servicename")
			}),
			Entry("service list", func() (any, error) {
				return dflowClient.ServiceList("namespace")
			}),
			Entry("service show", func() (any, error) {
				return dflowClient.ServiceShow("namespace", "servicename")
			}),
			Entry("service match", func() (any, error) {
				return dflowClient.ServiceMatch("namespace", "servicenameprefix")
			}),
			Entry("service match", func() (any, error) {
				return dflowClient.ServiceDelete(models.ServiceDeleteRequest{}, "namespace", nil)
			}),
			Entry("service apps", func() (any, error) {
				return dflowClient.ServiceApps("namespace")
			}),
		)
	})

	When("the server returns a non-JSON error", func() {
		BeforeEach(func() {
			statusCode = http.StatusBadGateway
			responseBody = "Bad Gateway"
		})

		It("reports the status without a JSON parse error", func() {
			old := os.Stderr
			r, w, err := os.Pipe()
			Expect(err).NotTo(HaveOccurred())
			os.Stderr = w

			_, callErr := dflowClient.ServiceCreate(models.ServiceCreateRequest{}, "namespace")

			Expect(w.Close()).To(Succeed())
			os.Stderr = old
			captured, err := io.ReadAll(r)
			Expect(err).NotTo(HaveOccurred())

			Expect(callErr).To(HaveOccurred())
			Expect(callErr.Error()).To(Equal("server unavailable (HTTP 502)"))
			Expect(string(captured)).NotTo(ContainSubstring("JSON PARSE ERROR"))
			Expect(string(captured)).NotTo(ContainSubstring("invalid character"))
			Expect(bytes.Contains(captured, []byte("Bad Gateway"))).To(BeFalse())
		})
	})

	When("the server returns HTML for a client error", func() {
		BeforeEach(func() {
			statusCode = http.StatusNotFound
			responseBody = "<html><body>not found</body></html>"
		})

		It("reports an unexpected response and hides the body", func() {
			old := os.Stderr
			r, w, err := os.Pipe()
			Expect(err).NotTo(HaveOccurred())
			os.Stderr = w

			_, callErr := dflowClient.ServiceCreate(models.ServiceCreateRequest{}, "namespace")

			Expect(w.Close()).To(Succeed())
			os.Stderr = old
			captured, err := io.ReadAll(r)
			Expect(err).NotTo(HaveOccurred())

			Expect(callErr).To(HaveOccurred())
			Expect(callErr.Error()).To(Equal("unexpected response from server (HTTP 404)"))
			Expect(string(captured)).NotTo(ContainSubstring("JSON PARSE ERROR"))
			Expect(string(captured)).NotTo(ContainSubstring("<html>"))
			Expect(string(captured)).NotTo(ContainSubstring("not found"))
		})
	})

	When("the server returns 503", func() {
		BeforeEach(func() {
			statusCode = http.StatusServiceUnavailable
			responseBody = "Service Unavailable"
		})

		It("reports the server as unavailable", func() {
			_, callErr := dflowClient.ServiceCreate(models.ServiceCreateRequest{}, "namespace")
			Expect(callErr).To(HaveOccurred())
			Expect(callErr.Error()).To(Equal("server unavailable (HTTP 503)"))
		})
	})

	When("the server returns 504", func() {
		BeforeEach(func() {
			statusCode = http.StatusGatewayTimeout
			responseBody = "Gateway Timeout"
		})

		It("reports the server as unavailable", func() {
			_, callErr := dflowClient.ServiceCreate(models.ServiceCreateRequest{}, "namespace")
			Expect(callErr).To(HaveOccurred())
			Expect(callErr.Error()).To(Equal("server unavailable (HTTP 504)"))
		})
	})
}
