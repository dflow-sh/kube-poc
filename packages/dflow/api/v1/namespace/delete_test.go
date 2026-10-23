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

package namespace

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestNamespacesFromRequestUsesPathWhenPresent(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodDelete, "/namespaces/mine?namespaces[]=other&namespaces[]=", nil)
	c.Params = gin.Params{{Key: "namespace", Value: "mine"}}

	got := namespacesFromRequest(c)
	if len(got) != 1 || got[0] != "mine" {
		t.Fatalf("path namespace = %q, want [mine]", got)
	}
}

func TestNamespacesFromRequestUsesQueryWithoutPath(t *testing.T) {
	gin.SetMode(gin.TestMode)
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodDelete, "/namespaces?namespaces[]=mine&namespaces[]=other", nil)

	got := namespacesFromRequest(c)
	if len(got) != 2 || got[0] != "mine" || got[1] != "other" {
		t.Fatalf("query namespaces = %q, want [mine other]", got)
	}
}

func TestRequireNamespaceNamesRejectsEmpty(t *testing.T) {
	if err := requireNamespaceNames(nil); err == nil || err.FirstStatus() != http.StatusBadRequest {
		t.Fatalf("missing names status = %v, want 400", err)
	}
	if err := requireNamespaceNames([]string{"mine", ""}); err == nil || err.FirstStatus() != http.StatusBadRequest {
		t.Fatalf("empty name status = %v, want 400", err)
	}
	if err := requireNamespaceNames([]string{"mine"}); err != nil {
		t.Fatalf("owned name rejected: %v", err)
	}
}
