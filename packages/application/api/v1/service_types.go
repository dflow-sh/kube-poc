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

package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// EDIT THIS FILE!  THIS IS SCAFFOLDING FOR YOU TO OWN!
// NOTE: json tags are required.  Any new fields you add must have json tags for the fields to be serialized.

// ServiceSpec defines the desired state of Service
type ServiceSpec struct {
	// INSERT ADDITIONAL SPEC FIELDS - desired state of cluster
	// Important: Run "make" to regenerate code after modifying this file

	// Name of the service (i.e. redis-small)
	Name string `json:"name,omitempty"`

	// ShortDescription of the service to be used in lists
	ShortDescription string `json:"shortDescription,omitempty"`

	// Description of the service to be used when the service is described
	Description string `json:"description,omitempty"`

	// HelmRepo is the Helm repository where to fetch the helm chart
	HelmRepo HelmRepo `json:"helmRepo,omitempty"`

	// HelmChart is the name of the Helm chart used to deploy the service
	HelmChart string `json:"chart,omitempty"`

	// ChartVersion is the version of the Helm chart used to deploy the service
	ChartVersion string `json:"chartVersion,omitempty"`

	// AppVersion is the version of the service deployed by the referenced chart
	AppVersion string `json:"appVersion,omitempty"`

	// Values are the values provided by the operator.
	// They are used to customize the deployment of the service.
	Values string `json:"values,omitempty"`

	// ServiceIcon is an image associated with this service
	ServiceIcon string `json:"serviceIcon,omitempty"`

	// Settings declares the fields the user is allowed to customize when deploying
	// a service with the helm chart referenced by this service class.
	Settings map[string]ServiceSetting `json:"settings,omitempty"`

	// To expand and clarify the above a bit more:
	//
	// - `Values` is the service class configuring the helm chart. This enables the operator to
	//   create multiple service classes based on the same helm chart, as predefined setups the
	//   application developer can then select from.
	//
	// - `Settings` is telling the client(s) which fields of the helm chart the application
	//   developer is allowed to change. I.e. the knobs available to the application developer
	//   to tune the deployment of a service instance with the given service class.
	//
	// ATTENTION: In contrast to application charts the service classes have no real control
	// over the helm charts they are working with.
	//
	// Application charts can properly separate operator values from user values, with their API
	// to the helm charts to use under the control of the dFlow developers. IOW dFlow
	// specifies the rules a helmchart to be used in an application chart has to follow.
	//
	// Service classes cannot do this. The helm charts providing service instances on deployment
	// are in control. dFlow's service classes have to adapt.
	//
	// For `Settings` this means that the string keys are __not__ simple map element names used
	// in a specific and known field of `.Values` (`.Values.userValues` for apps).
	//
	// They are complex path specs as seen by helm `--set` options.
	//
	// And they naturally can overlap with whatever is specified by `Values`. Due to this a
	// resolution order is specified: System settings in field `Values` have priority over the
	// user `Settings`. This is necessary because the system settings are expected to contain
	// things which make the helm chart work within the dFlow context, and we cannot have users
	// break such.
}

// ServiceSetting is an alias to ChartSetting.
// Should reduce misunderstandings of what kind of settings are handled in a particular context.
type ServiceSetting ChartSetting

// HelmRepo is the Helm repository where to fetch the helm chart
type HelmRepo struct {
	Name   string `json:"name,omitempty"`
	URL    string `json:"url,omitempty"`
	Secret string `json:"secret,omitempty"`
}

// ServiceStatus defines the observed state of Service
type ServiceStatus struct {
	// INSERT ADDITIONAL STATUS FIELD - define observed state of cluster
	// Important: Run "make" to regenerate code after modifying this file
}

// The `ChartSetting` type is defined in sibling file `appchart_types.go`.

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status

// Service is the Schema for the services API
type Service struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ServiceSpec   `json:"spec,omitempty"`
	Status ServiceStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true

// ServiceList contains a list of Service
type ServiceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Service `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Service{}, &ServiceList{})
}
