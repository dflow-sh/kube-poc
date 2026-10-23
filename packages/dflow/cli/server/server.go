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

// Package server provides the dFlow http server
package server

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"

	apiv1 "github.com/dflow-sh/kube-poc/packages/dflow/api/v1"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/application"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/middleware"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/auth"
	"github.com/dflow-sh/kube-poc/packages/dflow/domain"
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers"
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	apierrors "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/tracing"
	"github.com/dflow-sh/kube-poc/packages/dflow/version"
	"github.com/pkg/errors"

	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"

	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
)

// apiMiddleware is the authenticated REST chain.
// gitconfig authorization is enforced in the handlers (read allows global,
// delete is owner/admin only), which the middleware cannot express without
// loading the resource.
func apiMiddleware() []gin.HandlerFunc {
	return []gin.HandlerFunc{
		middleware.Authentication,
		middleware.DFlowVersion,
		middleware.NamespaceExists,
		middleware.RoleAuthorization,
		middleware.NamespaceAuthorization,
	}
}

// websocketMiddleware is the authenticated websocket chain.
// TokenAuth stores the user it just read, and NamespaceAuthorization uses
// that user. gitconfig has no websocket routes.
func websocketMiddleware() []gin.HandlerFunc {
	return []gin.HandlerFunc{
		middleware.TokenAuth,
		middleware.DFlowVersion,
		middleware.NamespaceExists,
		middleware.RoleAuthorization,
		middleware.NamespaceAuthorization,
	}
}

// corsAllowOrigin chooses the Access-Control-Allow-Origin value.
// A single configured origin is sent as-is. A list echoes the request Origin
// when that origin is allowed. Credentials cannot be combined with "*".
func corsAllowOrigin(r *http.Request, allowed []string) string {
	if len(allowed) == 1 && allowed[0] != "*" {
		return allowed[0]
	}

	origin := strings.TrimSuffix(strings.TrimSpace(r.Header.Get("Origin")), "/")
	for _, allowedOrigin := range allowed {
		if allowedOrigin == "*" {
			if origin != "" {
				return origin
			}
			return "*"
		}
		if origin != "" && allowedOrigin == origin {
			return origin
		}
	}
	return ""
}

// setCORSHeaders writes the CORS response headers for one request.
// Access-Control-Allow-Credentials is omitted when the allow-list echoes
// for "*", because credentials cannot be combined with a wildcard origin.
func setCORSHeaders(ctx *gin.Context, allowed []string) {
	header := corsAllowOrigin(ctx.Request, allowed)
	if header == "" {
		return
	}

	ctx.Header("Access-Control-Allow-Origin", header)
	if corsAllowsCredentials(allowed) {
		ctx.Header("Access-Control-Allow-Credentials", "true")
	}
	// These cannot be wildcards when Access-Control-Allow-Credentials is true.
	ctx.Header("Access-Control-Allow-Methods", "POST, PUT, PATCH, GET, OPTIONS, DELETE")
	ctx.Header("Access-Control-Allow-Headers", "Authorization,x-api-csrf,content-type,file-size")
	ctx.Header("Vary", "Origin")
}

func corsAllowsCredentials(allowed []string) bool {
	for _, origin := range allowed {
		if origin == "*" {
			return false
		}
	}
	return true
}

// tracedPath reports whether a request should be traced by the otelgin
// middleware. Websocket connections are long-running, so a span covering
// their whole lifetime doesn't represent a meaningful unit of work and
// would just sit open in the collector.
func tracedPath(r *http.Request) bool {
	return !strings.HasPrefix(r.URL.Path, apiv1.WsRoot)
}

// NewHandler creates and setup the gin router
func NewHandler() (*gin.Engine, error) {
	rolesInitialized := false

	// Disable gin's default logger - we use zap logger via middleware.GinLogger
	gin.SetMode(gin.ReleaseMode)
	gin.DisableConsoleColor()

	// Endpoint structure ...
	// | Path              | Notes      | Logging
	// | ---               | ---        | ----
	// | <Root>/...        | API        | Via "<Root>" Group
	// | /ready            | L/R Probes |
	// | /namespaces/target/:namespace | ditto      | ditto

	// Use gin.New() instead of gin.Default() to avoid gin's default logger
	// All logging is handled by zap via middleware.GinLogger
	router := gin.New()
	router.HandleMethodNotAllowed = true
	router.NoMethod(func(ctx *gin.Context) {
		response.Error(ctx, apierrors.NewAPIError("Method not allowed", http.StatusMethodNotAllowed))
	})
	router.NoRoute(func(ctx *gin.Context) {
		response.Error(ctx, apierrors.NewNotFoundError("route", ctx.Request.URL.Path))
	})

	// An empty allow-list sets no CORS header. Browser callers are then limited
	// to same-origin, which matches the websocket CheckOrigin rule.
	allowedOrigins := application.SplitAllowOrigins(viper.GetString("access-control-allow-origin"))
	if len(allowedOrigins) > 0 {
		router.Use(func(ctx *gin.Context) {
			setCORSHeaders(ctx, allowedOrigins)

			if ctx.Request.Method == "OPTIONS" {
				// OPTIONS requests don't support `Authorization` headers, so return before we hit any checks
				ctx.AbortWithStatus(http.StatusNoContent)
				return
			}
		})
	}

	// Register routes - No authentication, no logging, no session.
	// This is the healthcheck.
	router.GET("/ready", func(c *gin.Context) {
		if rolesInitialized {
			c.JSON(http.StatusOK, gin.H{})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{
				"message": "Roles are not yet initialized",
			})
		}
	})
	// And the API self-description
	router.GET("/api/swagger.json", swaggerHandler)

	// Add common middlewares to all the routes declared after
	router.Use(
		otelgin.Middleware(tracing.ServiceName, otelgin.WithFilter(tracedPath)),
		middleware.GinLogger(),
		middleware.Recovery,
		middleware.InitContext(),
	)

	// No authentication, no session. This is dflow's version and auth information.
	router.GET("/api/v1/info",
		middleware.DFlowVersion,
		apiv1.ErrorHandler(apiv1.Info),
	)

	// authenticated /me endpoint returns the current user (no other checks/middlewares needed)
	router.GET("/api/v1/me",
		middleware.Authentication,
		middleware.DFlowVersion,
		apiv1.ErrorHandler(apiv1.Me),
	)

	// Dex or no dex ?
	if _, err := os.Stat(apiv1.DexPEMPath); err == nil {
		// dex secret is present, load contained cert

		err := auth.ExtendLocalTrustFromFile(apiv1.DexPEMPath)
		if err != nil {
			return nil, errors.Wrap(err, "extending local trust with dex")
		}
	} else if errors.Is(err, os.ErrNotExist) {
		// No dex secret/file, do nothing
	} else {
		// Some other Stat error, report
		return nil, errors.Wrap(err, "extending local trust with dex")
	}

	// Register api routes
	{
		apiRoutesGroup := router.Group(apiv1.Root, apiMiddleware()...)
		apiv1.Lemon(apiRoutesGroup)
	}

	// Register web socket routes
	{
		wapiRoutesGroup := router.Group(apiv1.WsRoot, websocketMiddleware()...)
		apiv1.Spice(wapiRoutesGroup)
	}

	cluster, err := kubernetes.GetCluster(context.Background())
	if err != nil {
		return nil, err
	}
	authservice := auth.NewAuthService(cluster)

	if err := apiv1.InitAuthAndRoles(authservice); err != nil {
		return nil, errors.Wrap(err, "initializing authentication")
	}
	rolesInitialized = true

	// print all registered routes at debug level
	if helpers.Logger != nil {
		for _, h := range router.Routes() {
			helpers.Logger.Debugw("registered route", "method", h.Method, "path", h.Path)
		}
	}

	return router, nil
}

func swaggerHandler(c *gin.Context) {
	swaggerFile, err := os.Open("swagger.json")
	if err != nil {
		response.Error(c, apierrors.InternalError(err))
		c.Abort()
		return
	}
	defer swaggerFile.Close()

	var swaggerMap map[string]interface{}
	err = json.NewDecoder(swaggerFile).Decode(&swaggerMap)
	if err != nil {
		response.Error(c, apierrors.InternalError(err))
		c.Abort()
		return
	}
	setSwaggerVersion(swaggerMap, version.Version)

	mainDomain, err := domain.MainDomain(c.Request.Context())
	if err != nil {
		response.Error(c, apierrors.InternalError(err))
		c.Abort()
		return
	}
	swaggerMap["host"] = "dflow." + mainDomain

	c.JSON(http.StatusOK, swaggerMap)
}

// setSwaggerVersion reports the stamped product version in OpenAPI info.version.
func setSwaggerVersion(swaggerMap map[string]interface{}, productVersion string) {
	info, _ := swaggerMap["info"].(map[string]interface{})
	if info == nil {
		info = map[string]interface{}{}
		swaggerMap["info"] = info
	}
	info["version"] = productVersion
}
