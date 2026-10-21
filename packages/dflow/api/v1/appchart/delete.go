package appchart

import (
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/appchart"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/gin-gonic/gin"
)

// Delete handles the API endpoint DELETE /appcharts/:name
func Delete(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()
	log := requestctx.Logger(ctx)
	chartName := c.Param("name")

	log.Infow("delete appchart", "name", chartName)
	defer log.Infow("return")

	cluster, clusterError := kubernetes.GetCluster(ctx)
	if clusterError != nil {
		return apierror.InternalError(clusterError)
	}

	client, clientError := cluster.ClientAppChart()
	if clientError != nil {
		return apierror.InternalError(clientError)
	}

	log.Infow("check existence", "name", chartName)
	exists, existsError := appchart.Exists(ctx, client, chartName)
	if existsError != nil {
		return apierror.InternalError(existsError)
	}
	if !exists {
		return apierror.AppChartIsNotKnown(chartName)
	}

	// This also removes the chart from dFlow's registry, if the application chart was pushed.
	log.Infow("delete appchart resource", "name", chartName)
	deleteError := appchart.DeleteWithChart(ctx, client, chartStoreOpener(cluster), chartName)

	if deleteError != nil {
		return apierror.InternalError(deleteError)
	}

	log.Infow("appchart deleted", "name", chartName)
	response.OK(c)
	return nil
}
