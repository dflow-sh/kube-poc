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
	"net/http"
	"strings"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/deploy"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/application"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	"github.com/gin-gonic/gin"
)

// Restart handles the API endpoint POST /namespaces/:namespace/applications/:app/restart
func Restart(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()
	namespace := c.Param("namespace")
	appName := c.Param("app")
	username := requestctx.User(ctx).Username

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}

	app, err := application.Lookup(ctx, cluster, namespace, appName)
	if err != nil {
		return apierror.InternalError(err)
	}

	if app == nil {
		return apierror.AppIsNotKnown(appName)
	}

	if app.Configuration.Instances == nil || *app.Configuration.Instances == 0 {
		return apierror.NewAPIError("No restart possible for an application with no instances", http.StatusBadRequest)
	}

	if !strings.Contains(app.ImageURL, app.StageID) {
		// The stage id should be contained in the image url (as image tag).  As it is not
		// found we conclude that the app was restaged, and restart now has to bring this
		// version up.

		// Recompute the image url, by replacing the old image tag (= old stage id) with the
		// new stage id.

		pieces := strings.Split(app.ImageURL, ":")
		pieces[len(pieces)-1] = app.StageID
		newImageURL := strings.Join(pieces, ":")

		// .. and save it for `DeployApp` to find.

		appRef := models.NewAppRef(appName, namespace)
		applicationCR, err := application.Get(ctx, cluster, appRef)
		if err != nil {
			return apierror.InternalError(err, "getting the application resource")
		}
		err = deploy.UpdateImageURL(ctx, cluster, applicationCR, newImageURL)
		if err != nil {
			return apierror.InternalError(err, "updating application's image url")
		}
	}

	_, apierr := deploy.DeployAppWithRestart(ctx, cluster, app.Meta, username, "")
	if apierr != nil {
		return apierr
	}

	response.OK(c)
	return nil
}
