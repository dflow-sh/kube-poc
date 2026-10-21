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

package namespace

import (
	"context"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/application"
	"github.com/dflow-sh/kube-poc/packages/dflow/configurations"
	"github.com/dflow-sh/kube-poc/packages/dflow/namespaces"
	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"

	"github.com/gin-gonic/gin"
)

// Show handles the API endpoint GET /namespaces/:namespace
// It returns the details of the specified namespace
func Show(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()
	namespace := c.Param("namespace")

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}

	appNames, err := namespaceApps(ctx, cluster, namespace)
	if err != nil {
		return apierror.InternalError(err)
	}

	configurationNames, err := namespaceConfigurations(ctx, cluster, namespace)
	if err != nil {
		return apierror.InternalError(err)
	}

	space, err := namespaces.Get(ctx, cluster, namespace)
	if err != nil {
		return apierror.InternalError(err)
	}

	response.OKReturn(c, models.Namespace{
		Meta: models.MetaLite{
			Name:      namespace,
			CreatedAt: space.CreatedAt,
		},
		Apps:           appNames,
		Configurations: configurationNames,
	})
	return nil
}

func namespaceApps(ctx context.Context, cluster *kubernetes.Cluster, namespace string) ([]string, error) {
	// Retrieve app references for namespace, and reduce to their names.
	appRefs, err := application.ListAppRefs(ctx, cluster, namespace)
	if err != nil {
		return nil, err
	}
	appNames := make([]string, 0, len(appRefs))
	for _, app := range appRefs {
		appNames = append(appNames, app.Name)
	}

	return appNames, nil
}

func namespaceConfigurations(ctx context.Context, cluster *kubernetes.Cluster, namespace string) ([]string, error) {
	// Retrieve configurations for namespace, and reduce to their names.
	configurations, err := configurations.List(ctx, cluster, namespace)
	if err != nil {
		return nil, err
	}
	configurationNames := make([]string, 0, len(configurations))
	for _, configuration := range configurations {
		configurationNames = append(configurationNames, configuration.Name)
	}

	return configurationNames, nil
}
