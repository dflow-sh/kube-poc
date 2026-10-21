// Copyright © 2021 - 2023 SUSE LLC
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package machine

import (
	"encoding/json"
	"os"
	"strings"

	. "github.com/onsi/gomega"
	"golang.org/x/crypto/bcrypt"

	"github.com/dflow-sh/kube-poc/acceptance/helpers/catalog"
	"github.com/dflow-sh/kube-poc/acceptance/helpers/proc"
	"github.com/dflow-sh/kube-poc/packages/dflow/names"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// CreatedFlowUser creates a new "user" BasicAuth Secret labeled as a dFlow User.
func (m *Machine) CreatedFlowUser(role string, namespaces []string) (string, string) {
	user, password := catalog.NewUserCredentials()
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	Expect(err).ToNot(HaveOccurred())

	secret := &corev1.Secret{
		TypeMeta: metav1.TypeMeta{
			Kind: "Secret",
			APIVersion: "v1",
		},
		Type: "Opaque",
		ObjectMeta: metav1.ObjectMeta{
			Name: names.GenerateResourceName("ruser", "test", user),
			Namespace: "dflow",
			Labels: map[string]string{
				"dflow.sh/api-user-credentials": "true",
				"dflow.sh/role": role,
			},
		},
		StringData: map[string]string{
			"username": user,
			"password": string(hashedPassword),
			"namespaces": strings.Join(namespaces, "\n"),
		},
	}

	// build roles (default for global role, and admin for its namespaces)
	roles := []string{role}
	for _, namespace := range namespaces {
		roles = append(roles, "admin:"+namespace)
	}

	secret.Annotations = map[string]string{
		"dflow.sh/roles": strings.Join(roles, ","),
	}

	secretTmpFile := catalog.NewTmpName("tmpUserFile") + `.json`
	//nolint:gosec // Used in acceptance tests, no need to check for file inclusion
	file, err := os.Create(secretTmpFile)
	Expect(err).ToNot(HaveOccurred())

	err = json.NewEncoder(file).Encode(secret)
	Expect(err).ToNot(HaveOccurred())

	out, err := proc.Kubectl("apply", "-f", secretTmpFile)
	Expect(err).ToNot(HaveOccurred(), out)

	Expect(os.Remove(secretTmpFile)).ToNot(HaveOccurred())
	return user, password
}

// DeletedFlowUser deletes the relevant Kubernetes secret if it exists.
func (m *Machine) DeletedFlowUser(username string) error {
	secretName := names.GenerateResourceName("ruser", "test", username)
	out, err := proc.Kubectl("delete", "secret", "-n", "dflow", secretName, "--ignore-not-found")
	Expect(err).ToNot(HaveOccurred(), out)

	return nil
}
