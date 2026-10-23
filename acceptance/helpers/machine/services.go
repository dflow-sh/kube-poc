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

package machine

import (
	"fmt"

	"github.com/dflow-sh/kube-poc/acceptance/helpers/matchers"
	"github.com/dflow-sh/kube-poc/acceptance/helpers/proc"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func (m *Machine) HaveServiceInstance(serviceName string) {
	By(fmt.Sprintf("HSI %s", serviceName))

	// And check presence and readiness
	out, err := m.DFlow("", "service", "show", serviceName)
	Expect(err).ToNot(HaveOccurred(), out)
	Expect(out).To(ContainSubstring(serviceName))
	Expect(out).To(matchers.HaveATable(
		matchers.WithHeaders("KEY", "VALUE"),
		matchers.WithRow("Status", "deployed"),
	))
	By("HSI/ok")
}

func (m *Machine) MakeServiceInstance(serviceName, catalogService string) {
	GinkgoHelper()

	By(fmt.Sprintf("creating service %s -> %s", catalogService, serviceName))

	out, err := m.DFlow("", "service", "create", catalogService, serviceName, "--wait")
	Expect(err).ToNot(HaveOccurred(), out)

	// Wait for deployment to be ready (--wait may return before status is "deployed" in busy clusters)
	Eventually(func() string {
		out, err := m.DFlow("", "service", "show", serviceName)
		if err != nil {
			return ""
		}
		return out
	}, "5m", "5s").Should(
		And(
			ContainSubstring(serviceName),
			matchers.HaveATable(
				matchers.WithHeaders("KEY", "VALUE"),
				matchers.WithRow("Status", "deployed"),
			),
		),
	)

	outNamespace, err := m.DFlow(m.nodeTmpDir, "target")
	Expect(err).ToNot(HaveOccurred(), out)
	outPods, err := proc.Kubectl("get", "pods", "-A")
	Expect(err).ToNot(HaveOccurred(), out)
	outHelm, err := proc.Run("", false, "helm", "list", "-a", "-A")
	Expect(err).ToNot(HaveOccurred(), out)
	By(fmt.Sprintf("%s\nPods:\n%s\nHelm releases:\n%s\n", outNamespace, outPods, outHelm))

	By("CSI/ok")
}

func (m *Machine) DeleteService(serviceName string) {
	By("deleting service " + serviceName)

	out, err := m.DFlow("", "service", "delete", serviceName)
	ExpectWithOffset(1, err).ToNot(HaveOccurred(), out)
	Expect(out).To(ContainSubstring("Services Removed"))

	EventuallyWithOffset(1, func() string {
		out, err := m.DFlow("", "service", "list")
		Expect(err).ToNot(HaveOccurred(), out)
		return out
	}, "1m").ShouldNot(
		matchers.HaveATable(
			matchers.WithHeaders("NAME", "CREATED", "CATALOG SERVICE", "STATUS", "APPLICATIONS"),
			matchers.WithRow(serviceName, matchers.WithDate(), "mysql-dev", "(not-ready|deployed)", ""),
		),
	)
}
