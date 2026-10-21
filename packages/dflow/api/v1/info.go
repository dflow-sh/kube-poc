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

package v1

import (
	"os"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/builderimage"
	"github.com/dflow-sh/kube-poc/packages/dflow/version"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	"github.com/spf13/viper"

	"github.com/gin-gonic/gin"

	. "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
)

const VersionHeader = "dflow-version"
const DexPEMPath = "/etc/ssl/certs/dex-tls.pem"

// Info handles the API endpoint /info.  It returns version
// information for various dflow components.
func Info(c *gin.Context) APIErrors {
	ctx := c.Request.Context()

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return InternalError(err)
	}

	kubeVersion, err := cluster.GetVersion()
	if err != nil {
		return InternalError(err)
	}

	platform := cluster.GetPlatform()

	builderImageClient, err := cluster.ClientBuilderImage()
	if err != nil {
		return InternalError(err)
	}

	// builderimage.Default returns nil (no error) when listing is forbidden,
	// so we fall back to DEFAULT_BUILDER_IMAGE in that case as well.
	defaultBuilder, err := builderimage.Default(ctx, builderImageClient)
	if err != nil {
		return InternalError(err)
	}

	defaultBuilderImage := viper.GetString("default-builder-image")
	if defaultBuilder != nil {
		defaultBuilderImage = defaultBuilder.Image
	}

	_, dexError := os.Stat(DexPEMPath)

	response.OKReturn(c, models.InfoResponse{
		Version:             version.Version,
		Platform:            platform.String(),
		KubeVersion:         kubeVersion,
		DefaultBuilderImage: defaultBuilderImage,
		OIDCEnabled:         dexError == nil,
	})
	return nil
}
