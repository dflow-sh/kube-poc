package appchart

import (
	"context"

	"github.com/dflow-sh/kube-poc/packages/dflow/helmchart"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
)

func Delete(
	ctx context.Context,
	client dynamic.NamespaceableResourceInterface,
	name string,
) error {
	return client.
		Namespace(helmchart.Namespace()).
		Delete(ctx, name, metav1.DeleteOptions{})
}
