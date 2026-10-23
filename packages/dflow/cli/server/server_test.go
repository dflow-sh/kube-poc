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

package server

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	apiv1 "github.com/dflow-sh/kube-poc/packages/dflow/api/v1"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/middleware"
	"github.com/dflow-sh/kube-poc/packages/dflow/tracing"
	"github.com/dflow-sh/kube-poc/packages/dflow/version"
)

func TestServer(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Server Suite")
}

var _ = Describe("setSwaggerVersion", func() {
	It("replaces OpenAPI info.version with the product version", func() {
		spec := map[string]interface{}{
			"info": map[string]interface{}{
				"title":   "dFlow API",
				"version": "1.0.0",
			},
		}
		setSwaggerVersion(spec, version.Version)
		info := spec["info"].(map[string]interface{})
		Expect(info["version"]).To(Equal(version.Version))
		Expect(info["title"]).To(Equal("dFlow API"))
	})

	It("creates info when the document has none", func() {
		spec := map[string]interface{}{}
		setSwaggerVersion(spec, "v9.9.9")
		info := spec["info"].(map[string]interface{})
		Expect(info["version"]).To(Equal("v9.9.9"))
	})
})

var _ = Describe("websocket middleware", func() {
	It("includes namespace authorization after token auth", func() {
		chain := websocketMiddleware()
		Expect(handlerIndex(chain, middleware.TokenAuth)).To(BeNumerically(">=", 0))
		Expect(handlerIndex(chain, middleware.NamespaceAuthorization)).To(BeNumerically(">", handlerIndex(chain, middleware.TokenAuth)))
		Expect(handlerIndex(chain, middleware.RoleAuthorization)).To(BeNumerically(">=", 0))
	})
})

func handlerIndex(chain []gin.HandlerFunc, want gin.HandlerFunc) int {
	wantPtr := reflect.ValueOf(want).Pointer()
	for i, handler := range chain {
		if reflect.ValueOf(handler).Pointer() == wantPtr {
			return i
		}
	}
	return -1
}

var _ = Describe("tracedPath", func() {
	It("excludes websocket routes", func() {
		path := apiv1.WsRoot + "/namespaces/foo/applications/bar/exec"
		Expect(tracedPath(httptest.NewRequest(http.MethodGet, path, nil))).To(BeFalse())
	})

	It("includes regular API routes", func() {
		path := apiv1.Root + "/namespaces/foo/applications"
		Expect(tracedPath(httptest.NewRequest(http.MethodGet, path, nil))).To(BeTrue())
	})
})

var _ = Describe("otelgin wiring on the gin router", func() {
	var exporter *tracetest.InMemoryExporter

	apiPath := apiv1.Root + "/ping"
	wsPath := apiv1.WsRoot + "/ping"

	// Mirrors how NewHandler wires the middleware, but against an
	// in-memory exporter instead of the process-global TracerProvider so
	// the test is isolated and needs no real collector.
	newTracedRouter := func() *gin.Engine {
		exporter = tracetest.NewInMemoryExporter()
		tp := sdktrace.NewTracerProvider(sdktrace.WithSyncer(exporter))

		gin.SetMode(gin.TestMode)
		router := gin.New()
		router.Use(otelgin.Middleware(tracing.ServiceName,
			otelgin.WithTracerProvider(tp),
			otelgin.WithFilter(tracedPath),
		))
		router.GET(apiPath, func(c *gin.Context) { c.Status(http.StatusOK) })
		router.GET(wsPath, func(c *gin.Context) { c.Status(http.StatusOK) })
		return router
	}

	It("records a span for a request through a regular API route", func() {
		router := newTracedRouter()
		router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, apiPath, nil))

		Expect(exporter.GetSpans()).To(HaveLen(1))
	})

	It("records no span for a request through a websocket route", func() {
		router := newTracedRouter()
		router.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, wsPath, nil))

		Expect(exporter.GetSpans()).To(BeEmpty())
	})
})
