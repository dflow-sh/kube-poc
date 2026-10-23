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

package middleware

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	v1 "github.com/dflow-sh/kube-poc/packages/dflow/api/v1"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	"github.com/gin-gonic/gin"

	apierrors "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
)

// RoleAuthorization middleware is used to check if the user is allowed for the incoming request
// checking the verb, path and eventually the params of it.
func RoleAuthorization(c *gin.Context) {
	user := requestctx.User(c.Request.Context())

	params := map[string]string{}
	for _, p := range c.Params {
		params[p.Key] = p.Value
	}

	allowed := user.IsAllowed(c.Request.Method, c.FullPath(), params)

	if !allowed {
		err := apierrors.NewAPIError("user unauthorized", http.StatusForbidden)
		response.Error(c, err)
		c.Abort()
		return
	}
}

// NamespaceAuthorization ensures the user is allowed to access the requested namespace.
// Only admins may access any namespace; all other users are restricted to namespaces
// listed in their Secret's "namespaces" field.
//
// The user is the one Authentication or TokenAuth already stored on the request.
// TokenAuth loads that user with a direct secret read, so this check does not
// use a namespace list that can lag behind the secret.
func NamespaceAuthorization(c *gin.Context) {
	user := requestctx.User(c.Request.Context())
	authorization(c, "namespace", user.Namespaces)
}

func authorization(c *gin.Context, label string, allowed []string) {
	ctx := c.Request.Context()
	logger := requestctx.Logger(ctx).With("component", "AuthorizationMiddleware")
	user := requestctx.User(ctx)

	method := c.Request.Method
	path := c.Request.URL.Path

	roleIDs := strings.Join(user.Roles.IDs(), ",")
	logger.Infow("authorization request",
		"user", user.Username,
		"roles", roleIDs,
		"method", method,
		"path", path,
	)

	if user.IsAdmin() {
		logger.Debugw("user [admin] is authorized", "component", "authorizeAdmin")
		return
	}

	// not an admin, check if path is restricted
	if restrictedPath(ctx, path) {
		err := apierrors.NewAPIError("user unauthorized, path restricted", http.StatusForbidden)
		response.Error(c, err)
		c.Abort()
		return
	}

	// A route with a path parameter is authorized on that value alone.
	// The query list is used only when the route has no path parameter.
	// A request that names no resource is not namespace-scoped.
	resourceNames, explicit := scopedResources(c, label)
	if !explicit {
		return
	}

	for _, rsrc := range resourceNames {
		authorized := authorizeUser(ctx, label, rsrc, allowed)

		roleIDs := strings.Join(user.Roles.IDs(), ",")
		logger.Infow("authorization result",
			"user", user.Username,
			"roles", roleIDs,
			"authorized", authorized,
			"resource_type", label,
			"resource", rsrc,
		)

		if !authorized {
			err := apierrors.NewAPIError(fmt.Sprintf("user unauthorized for %s %s", label, rsrc), http.StatusForbidden)
			response.Error(c, err)
			c.Abort()
			return
		}
	}
}

func authorizeUser(ctx context.Context, label, resource string, allowed []string) bool {
	logger := requestctx.Logger(ctx).With("component", "authorizeUser")

	// An explicit empty value is not a namespace the user may access.
	// Requests that name no resource return before this check.
	if resource == "" {
		logger.Infow("empty resource is not permitted", "resource_type", label)
		return false
	}

	for _, ns := range allowed {
		if resource == ns {
			return true
		}
	}

	logger.Infow("resource not in allowed list",
		"resource_type", label,
		"resource", resource,
		"allowed", strings.Join(allowed, ", "))
	return false
}

// scopedResources reports the resource names this request must be allowed
// to use. The boolean is false when the request does not name a resource.
func scopedResources(c *gin.Context, label string) ([]string, bool) {
	if resource, ok := c.Params.Get(label); ok {
		return []string{resource}, true
	}

	query, found := c.GetQueryArray(label + "s[]")
	if !found {
		return nil, false
	}
	if len(query) == 0 {
		return []string{""}, true
	}
	return query, true
}

func restrictedPath(ctx context.Context, path string) bool {
	logger := requestctx.Logger(ctx).With("component", "unrestrictedPath")

	// check if the requested path is restricted
	if _, found := v1.AdminRoutes[path]; found {
		logger.Infow("path is an admin route, user unauthorized", "path", path)
		return true
	}

	// path is free to use
	return false
}
