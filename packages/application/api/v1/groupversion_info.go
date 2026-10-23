/*
Copyright 2021.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package v1 contains API Schema definitions for the application v1 API group
// +kubebuilder:object:generate=true
// +groupName=application.dflow.sh
package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var (
	// GroupVersion is group version used to register these objects
	GroupVersion = schema.GroupVersion{Group: "application.dflow.sh", Version: "v1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	// This is the apimachinery builder. The controller-runtime helper is deprecated
	// because API packages should not depend on it.
	SchemeBuilder = &schemeBuilder{groupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)

// schemeBuilder registers Go types for one GroupVersion without pulling in
// controller-runtime. Register matches the previous helper's call sites.
type schemeBuilder struct {
	groupVersion schema.GroupVersion
	runtime.SchemeBuilder
}

func (b *schemeBuilder) Register(object ...runtime.Object) *schemeBuilder {
	b.SchemeBuilder.Register(func(scheme *runtime.Scheme) error {
		scheme.AddKnownTypes(b.groupVersion, object...)
		metav1.AddToGroupVersion(scheme, b.groupVersion)
		return nil
	})
	return b
}
