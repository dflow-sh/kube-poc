/* -*- fill-column: 90 -*-
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

package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the
// fields to be serialized.

// AppSpec defines the desired state of App
type AppSpec struct {
	// INSERT ADDITIONAL SPEC FIELDS - desired state of cluster
	// Important: Run "make" to regenerate code after modifying this file

	Routes []string  `json:"routes,omitempty"`
	Origin AppOrigin `json:"origin"`
	// This field stores the builder image that was used when the application was last
	// staged (from code). It can be empty if the application was never staged
	// (e.g. pushed with container image). dFlow will use the builder image set by
	// the user explicitly but if one is not set, it will try to use the previously
	// set image.
	BuilderImage string `json:"builderimage,omitempty"`

	// BlobUID stores the blob uid that was used when the application was last staged
	// (from code). It can be empty if the application was never staged (e.g. pushed
	// with container image). dFlow will use the value set by the user explicitly but
	// if one is not set, it will try to use the previously set blobUID from the
	// application CRD.
	BlobUID string `json:"blobuid,omitempty"`

	// StageID stores the id of the latest attempt to stage the application,
	// regardless of outcome. This enables access to the staging logs of an
	// application which never staged successfully.
	StageID string `json:"stageid,omitempty"`

	// ImageURL stores the image reference of the currently running application. This
	// is set on deployment, for use in updates.
	ImageURL string `json:"imageurl,omitempty"`

	// ChartName stores the name of the application support chart used to deploy the
	// currently running application. This is set on deployment, for use in
	// updates. The name references a dflow AppCharts resource.
	ChartName string `json:"chartname,omitempty"`

	// Settings stores the fields and values set by the user to configure the
	// application chart. See ChartName.
	Settings map[string]string `json:"settings,omitempty"`
}

type AppOrigin struct {
	Path      *string        `json:"path,omitempty"`
	Container *string        `json:"container,omitempty"`
	Git       *AppRepository `json:"git,omitempty"`
	Archive   bool           `json:"archive,omitempty"`
}

type AppRepository struct {
	Repository string  `json:"repository"`
	Revision   *string `json:"revision,omitempty"`
	Provider   *string `json:"provider,omitempty"`
	Branch     *string `json:"branch,omitempty"`
}

// AppStatus defines the observed state of App
type AppStatus struct {
	// INSERT ADDITIONAL STATUS FIELD - define observed state of cluster
	// Important: Run "make" to regenerate code after modifying this file
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status

// App is the Schema for the apps API
type App struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AppSpec   `json:"spec,omitempty"`
	Status AppStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// AppList contains a list of App
type AppList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []App `json:"items"`
}

func init() {
	SchemeBuilder.Register(&App{}, &AppList{})
}
