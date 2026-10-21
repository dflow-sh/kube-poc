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

package application

import (
	"strings"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/application"
	"github.com/dflow-sh/kube-poc/packages/dflow/auth"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"

	"github.com/gin-gonic/gin"
)

// FullIndex handles the API endpoint GET /applications
// It lists all the known applications in all namespaces, with and without workload.
func FullIndex(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()
	user := requestctx.User(ctx)

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}

	allApps, err := application.List(ctx, cluster, "")
	if err != nil {
		return apierror.InternalError(err)
	}

	namespaces := response.GetNamespacesParam(c)

	filteredApps := auth.FilterResources(user, allApps)
	filteredApps = auth.FilterByNamespaces(filteredApps, namespaces)

	if search := response.GetSearchParam(c); search != "" {
		lower := strings.ToLower(search)
		var searched models.AppList
		for _, a := range filteredApps {
			if strings.Contains(strings.ToLower(a.Meta.Name), lower) {
				searched = append(searched, a)
			}
		}
		filteredApps = searched
	}

	// Apply optional pagination when page parameters are provided.
	if page, pageSize, ok := response.GetPaginationParams(c, 1, 25); ok {
		paged := response.PaginateSlice(filteredApps, page, pageSize)
		response.OKReturn(c, paged)
		return nil
	}

	// Backwards-compatible: return full list when no page params are set.
	response.OKReturn(c, filteredApps)
	return nil
}
