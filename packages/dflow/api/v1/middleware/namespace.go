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
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	"github.com/dflow-sh/kube-poc/packages/dflow/namespaces"
	"github.com/gin-gonic/gin"

	apierrors "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
)

// NamespaceExists is a gin middleware used to check if a namespaced route is valid.
// It checks the validity of the requested namespace, returning a 404 if it doesn't exists
func NamespaceExists(c *gin.Context) {
	ctx := c.Request.Context()
	logger := requestctx.Logger(ctx).With("component", "NamespaceMiddleware")

	namespace := c.Param("namespace")
	if namespace == "" {
		return
	}

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		logger.Infow("unable to get cluster", "error", err)
		response.Error(c, apierrors.InternalError(err))
		c.Abort()
		return
	}

	exists, err := namespaces.Exists(ctx, cluster, namespace)
	if err != nil {
		logger.Infow("unable to check if namespace exists", "error", err)
		response.Error(c, apierrors.InternalError(err))
		c.Abort()
		return
	}

	if !exists {
		logger.Infow("namespace doesn't exist", "namespace", namespace)
		response.Error(c, apierrors.NamespaceIsNotKnown(namespace))
		c.Abort()
	}
}
