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
	"fmt"
	"sync"
	"time"

	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/application"
	"github.com/dflow-sh/kube-poc/packages/dflow/auth"
	"github.com/dflow-sh/kube-poc/packages/dflow/configurations"
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/namespaces"
	"github.com/dflow-sh/kube-poc/packages/dflow/services"
	"github.com/gin-gonic/gin"
	ants "github.com/panjf2000/ants/v2"
	"github.com/pkg/errors"
	apierrors "k8s.io/apimachinery/pkg/api/errors"

	apierror "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
)

// Delete handles the API endpoint /namespaces/:namespace (DELETE).
// It destroys the namespace specified by its name.
// This includes all the applications and configurations in it.
func Delete(c *gin.Context) apierror.APIErrors {
	ctx := c.Request.Context()

	// The batch route has no :namespace parameter and uses namespaces[].
	// A route that has the path parameter deletes that namespace only.
	namespaceNames := namespacesFromRequest(c)
	if err := requireNamespaceNames(namespaceNames); err != nil {
		return err
	}

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return apierror.InternalError(err)
	}

	authService := auth.NewAuthService(cluster)

	for _, namespace := range namespaceNames {
		err = deleteApps(ctx, cluster, namespace)
		if err != nil {
			return apierror.InternalError(err)
		}

		err = deleteServices(ctx, cluster, namespace)
		if err != nil {
			return apierror.InternalError(err)
		}

		// delete the namespace from all the Users
		err = authService.RemoveNamespaceFromUsers(ctx, namespace)
		if err != nil {
			errDetail := fmt.Sprintf("error removing namespace [%s] from users", namespace)
			return apierror.InternalError(err, errDetail)
		}

		configurationList, err := configurations.List(ctx, cluster, namespace)
		if err != nil {
			return apierror.InternalError(err)
		}

		for _, configuration := range configurationList {
			err = configuration.Delete(ctx)
			if err != nil && !apierrors.IsNotFound(err) {
				return apierror.InternalError(err)
			}
		}

		// Deleting the namespace here. That will automatically delete the application resources.
		err = namespaces.Delete(ctx, cluster, namespace)
		if err != nil {
			return apierror.InternalError(err)
		}
	}

	response.OK(c)
	return nil
}

// namespacesFromRequest selects the namespaces a delete applies to.
// Query values are ignored when the matched route has a path namespace.
func namespacesFromRequest(c *gin.Context) []string {
	if namespaceName, ok := c.Params.Get("namespace"); ok {
		return []string{namespaceName}
	}

	if namespaceNames, found := c.GetQueryArray("namespaces[]"); found {
		return namespaceNames
	}

	return nil
}

func requireNamespaceNames(namespaceNames []string) apierror.APIErrors {
	if len(namespaceNames) == 0 {
		return apierror.NewBadRequestError("namespace is required")
	}
	for _, namespaceName := range namespaceNames {
		if namespaceName == "" {
			return apierror.NewBadRequestError("namespace is required")
		}
	}
	return nil
}

// deleteApps removes the application and its resources
func deleteApps(ctx context.Context, cluster *kubernetes.Cluster, namespace string) error {
	appRefs, err := application.ListAppRefs(ctx, cluster, namespace)
	if err != nil {
		return err
	}

	const maxConcurrent = 100
	errChan := make(chan error)

	var wg, errWg sync.WaitGroup
	var loopErrs []error

	errWg.Add(1)
	go func() {
		for err := range errChan {
			loopErrs = append(loopErrs, err)
		}
		errWg.Done()
	}()

	p, err := ants.NewPoolWithFunc(maxConcurrent, func(i interface{}) {
		_, err := application.Delete(ctx, cluster, i.(models.AppRef), false, false)
		if err != nil {
			errChan <- err
		}
		wg.Done()
	}, ants.WithExpiryDuration(10*time.Second))
	if err != nil {
		return err
	}

	for _, appRef := range appRefs {
		wg.Add(1)
		err = p.Invoke(appRef)
		if err != nil {
			errChan <- err
		}
	}
	defer p.Release()

	wg.Wait()
	close(errChan)
	errWg.Wait()

	totalErrs := len(loopErrs)
	if totalErrs > 0 {
		return errors.Wrapf(loopErrs[1], "%d errors occurred. This is the first one", totalErrs)
	}

	return nil
}

// deleteServices removes all provisioned services when a Namespace is deleted
func deleteServices(ctx context.Context, cluster *kubernetes.Cluster, namespace string) error {
	kubeServiceClient, err := services.NewKubernetesServiceClient(cluster)
	if err != nil {
		return apierror.InternalError(err)
	}

	return kubeServiceClient.DeleteAll(ctx, namespace)
}
