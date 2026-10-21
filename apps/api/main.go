// Copyright © 2026 dFlow
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//     http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Command dflow-server runs the dFlow API. It is the same server as
// `dflow server`.
package main

import (
	"os"

	"github.com/dflow-sh/kube-poc/packages/dflow/cli"
)

func main() {
	os.Args = append([]string{"dflow", "server"}, os.Args[1:]...)
	cli.Execute()
}
