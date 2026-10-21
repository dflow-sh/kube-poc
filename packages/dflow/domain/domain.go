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

// Package domain collects structures and functions around the domains the client works with.
package domain

import (
	"context"
	"fmt"
	"strings"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/helmchart"
	"github.com/pkg/errors"
)

// mainDomain is the memoization cache for the name of the main domain of the currently accessed
// dflow installation.
var mainDomain = ""

// AppDefaultRoute constructs and returns an application's default route constructed from the main
// domain, and the name of the application.
func AppDefaultRoute(ctx context.Context, name, namespace string) (string, error) {
	mainDomain, err := MainDomain(ctx)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s.%s", name, mainDomain), nil
}

// MainDomain determines the name of the main domain of the currently accessed dflow
// installation. The result is cached in-memory (see variable mainDomain). The function preferably
// returns cached data, and queries the cluster ingresses only the first time the data is asked
// for. This is especially useful for long running commands. In other other words, dflow's API
// server.
func MainDomain(ctx context.Context) (string, error) {
	if mainDomain != "" {
		return mainDomain, nil
	}

	cluster, err := kubernetes.GetCluster(ctx)
	if err != nil {
		return "", err
	}

	// Get the dflow ingress
	ingresses, err := cluster.ListIngress(ctx, helmchart.Namespace(), "app.kubernetes.io/name=dflow")
	if err != nil {
		return "", errors.Wrap(err, "failed to list ingresses for dflow")
	}

	if len(ingresses.Items) > 1 {
		return "", errors.New("more than one dflow ingress found")
	}

	if len(ingresses.Items) == 1 {
		if len(ingresses.Items[0].Spec.Rules) < 1 {
			return "", errors.New("dflow ingress has no rules")
		}
		if len(ingresses.Items[0].Spec.Rules) > 1 {
			return "", errors.New("dflow ingress has more than one rule")
		}
		host := ingresses.Items[0].Spec.Rules[0].Host
		mainDomain = strings.TrimPrefix(host, "dflow.")
		return mainDomain, nil
	}

	// No ingress found — fall back to Gateway API HTTPRoute (gateway.enabled mode)
	host, err := cluster.GetdFlowHTTPRouteHostname(ctx, helmchart.Namespace())
	if err != nil {
		return "", errors.Wrap(err, "dflow domain not found: no ingress and no httproute")
	}
	mainDomain = strings.TrimPrefix(host, "dflow.")
	return mainDomain, nil
}
