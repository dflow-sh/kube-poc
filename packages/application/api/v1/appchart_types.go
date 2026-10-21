/* -*- fill-column: 80 -*-
Copyright 2021-2022.

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
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// AppChartSpec defines the desired state of AppChart
type AppChartSpec struct {
	// INSERT ADDITIONAL SPEC FIELDS - desired state of cluster
	// Important: Run "make" to regenerate code after modifying this file

	// ShortDescription of the chart. To be used in list displays
	ShortDescription string `json:"shortDescription,omitempty"`

	// Description of the chart. Long form to be used in detailed displays
	Description string `json:"description,omitempty"`

	// HelmRepo is the URL to the Helm repository where to fetch the helm
	// chart. This can be empty. In that case the HelmChart field has to
	// reference the chart as full URL instead of as a simple name.
	HelmRepo string `json:"helmRepo,omitempty"`

	// HelmChart is the name of the Helm chart used to deploy an application.
	HelmChart string `json:"helmChart,omitempty"`

	// Values provides settings, i.e. field names and values to customize
	// the referenced helm chart when deploying an application with this app
	// chart. Note that user-configurable settings are declared with
	// `Settings` instead. While nothing checks against exposing a field set
	// here to the user this is strongly discouraged, to avoid confusion.
	Values map[string]string `json:"values,omitempty"`

	// Settings declares the fields underneath `userValues` the user is
	// allowed to customize when deploying an application with the helm
	// chart referenced by this app chart.
	Settings map[string]ChartSetting `json:"settings,omitempty"`

	// To expand and clarify the above a bit more:
	//
	// - Values is the app chart configuring the helm chart. This enables
	//   the operator to create multiple app charts based on the same helm
	//   chart, as predefined setups the application developer can then
	//   select from.
	//
	// - Settings is telling the client(s) which config fields of the helm
	//   chart the application developer is allowed to change. I.e. the
	//   knobs available to the application developer to tune the deployment
	//   with the given app chart.
}

// AppChartStatus defines the observed state of AppChart
type AppChartStatus struct {
	// INSERT ADDITIONAL STATUS FIELD - define observed state of cluster
	// Important: Run "make" to regenerate code after modifying this file
}

// ChartSetting specifies a single setting applicable to a helm chart. This can
// be for an application chart (as defined in this file), or for service helm
// chart (See sibling file `service_types.go`).
type ChartSetting struct {
	// Type of the setting (string, bool, number, or integer)
	Type string `json:"type"`

	// Minimal allowed value, for number, integer
	Minimum string `json:"minimum,omitempty"`

	// Maximal allowed value, for number, integer
	Maximum string `json:"maximum,omitempty"`

	// Enumeration of allowed values, for types string, number, integer
	Enum []string `json:"enum,omitempty"`

	// Presence of an enum for number and integer overrides the min/max
	// specifications
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status

// AppChart is the Schema for the appcharts API
type AppChart struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AppChartSpec   `json:"spec,omitempty"`
	Status AppChartStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// AppChartList contains a list of AppChart
type AppChartList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AppChart `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AppChart{}, &AppChartList{})
}
