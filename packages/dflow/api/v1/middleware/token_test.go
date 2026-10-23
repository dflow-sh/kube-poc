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

package middleware

import (
	"errors"
	"net/http"
	"testing"

	"github.com/dflow-sh/kube-poc/packages/dflow/auth"
)

func TestLookupUserErrorMapsNotFoundToUnauthorized(t *testing.T) {
	notFound := lookupUserError(auth.ErrUserNotFound)
	if notFound.FirstStatus() != http.StatusUnauthorized {
		t.Fatalf("missing user status = %d, want 401", notFound.FirstStatus())
	}

	other := lookupUserError(errors.New("secret unavailable"))
	if other.FirstStatus() != http.StatusInternalServerError {
		t.Fatalf("other lookup status = %d, want 500", other.FirstStatus())
	}
}
