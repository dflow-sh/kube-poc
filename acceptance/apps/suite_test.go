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

package apps_test

import (
	"fmt"
	"os"
	"testing"

	"github.com/dflow-sh/kube-poc/acceptance/helpers/proc"
	"github.com/dflow-sh/kube-poc/acceptance/testenv"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/settings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestAcceptance(t *testing.T) {
	RegisterFailHandler(FailWithReport)
	RunSpecs(t, "Acceptance Suite for Application Tests")
}

var (
	nodeSuffix, nodeTmpDir string

	// serverURL is the URL of the dflow API server
	serverURL, websocketURL string

	env testenv.DFlowEnv
)

var _ = BeforeSuite(func() {
	fmt.Printf("Running tests on node %d\n", GinkgoParallelProcess())

	testenv.SetRoot("../..")
	testenv.SetupEnv()

	nodeSuffix = fmt.Sprintf("%d", GinkgoParallelProcess())
	nodeTmpDir, err := os.MkdirTemp("", "dflow-"+nodeSuffix)
	Expect(err).NotTo(HaveOccurred())

	out, err := testenv.CopydFlowSettings(nodeTmpDir)
	Expect(err).ToNot(HaveOccurred(), out)
	os.Setenv("DFLOW_SETTINGS", nodeTmpDir+"/dflow.yaml")

	config, err := settings.LoadFrom(nodeTmpDir + "/dflow.yaml")
	Expect(err).NotTo(HaveOccurred())

	env = testenv.New(nodeTmpDir, testenv.Root(), config.User, config.Password, "", "")

	out, err = proc.Run(testenv.Root(), false, "kubectl", "get", "ingress",
		"--namespace", "dflow", "dflow",
		"-o", "jsonpath={.spec.rules[0].host}")
	Expect(err).ToNot(HaveOccurred(), out)

	serverURL = "https://" + out
	websocketURL = "wss://" + out
})

var _ = AfterSuite(func() {
	if !testenv.SkipCleanup() {
		fmt.Printf("Deleting tmpdir on node %d\n", GinkgoParallelProcess())
		testenv.DeleteTmpDir(nodeTmpDir)
	}
})

var _ = AfterEach(func() {
	testenv.AfterEachSleep()
})

func FailWithReport(message string, callerSkip ...int) {
	// NOTE: Use something like the following if you need to debug failed tests
	// fmt.Println("\nA test failed. You may find the following information useful for debugging:")
	// fmt.Println("The cluster pods: ")
	// out, err := proc.Kubectl("get pods --all-namespaces")
	// if err != nil {
	// 	fmt.Print(err.Error())
	// } else {
	// 	fmt.Print(out)
	// }

	// Ensures the correct line numbers are reported
	Fail(message, callerSkip[0]+1)
}
