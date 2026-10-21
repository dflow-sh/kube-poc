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

package catalog

import (
	"strings"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/services"
	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	"github.com/gin-gonic/gin"
)

// Index handles GET /catalogservices
func Index(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}

	kubeServiceClient, err := services.NewKubernetesServiceClient(cluster)
	if err != nil {
		return apierror.InternalError(err)
	}

	serviceList, err := kubeServiceClient.ListCatalogServices(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}

	inUse, err := kubeServiceClient.CatalogServicesInUse(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}
	for _, svc := range serviceList {
		svc.BoundServices = inUse[svc.Meta.Name]
	}

	// Optional name filtering, applied before pagination so the page counts
	// describe the filtered set.
	if search := response.GetSearchParam(c); search != "" {
		lower := strings.ToLower(search)
		var filtered []*models.CatalogService
		for _, svc := range serviceList {
			if strings.Contains(strings.ToLower(svc.Meta.Name), lower) {
				filtered = append(filtered, svc)
			}
		}
		serviceList = filtered
	}

	// Apply optional pagination when page parameters are provided.
	if page, pageSize, ok := response.GetPaginationParams(c, 1, 25); ok {
		paged := response.PaginateSlice(serviceList, page, pageSize)
		response.OKReturn(c, paged)
		return nil
	}

	// Backwards-compatible: return full list when no page params are set.
	response.OKReturn(c, serviceList)
	return nil
}
