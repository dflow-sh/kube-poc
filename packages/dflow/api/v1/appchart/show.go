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

package appchart

import (
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/appchart"
	"github.com/dflow-sh/kube-poc/packages/dflow/application"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/gin-gonic/gin"
)

// Show handles the API endpoint GET /appcharts/:name
// It returns the details of the specified appchart.
func Show(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()
	log := requestctx.Logger(ctx)
	chartName := c.Param("name")

	log.Infow("show appchart", "name", chartName)
	defer log.Infow("return")

	cluster, clusterError := kubernetes.GetCluster(ctx)
	if clusterError != nil {
		return apierror.InternalError(clusterError)
	}

	client, clientError := cluster.ClientAppChart()
	if clientError != nil {
		return apierror.InternalError(clientError)
	}

	log.Infow("lookup appchart", "name", chartName)
	app, lookupError := appchart.Lookup(ctx, client, chartName)
	if lookupError != nil {
		return apierror.InternalError(lookupError)
	}

	if app == nil {
		return apierror.AppChartIsNotKnown(chartName)
	}

	inUse, inUseError := application.ChartsInUse(ctx, cluster)
	if inUseError != nil {
		return apierror.InternalError(inUseError)
	}
	app.BoundApps = inUse[chartName]

	log.Infow("deliver appchart", "name", chartName)
	// Note: Returning only the public parts. The local config
	// data is not handed to the user. Only the setting specs.
	response.OKReturn(c, app)
	return nil
}
