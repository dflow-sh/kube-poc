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

package middleware

import (
	"bytes"
	"fmt"

	"github.com/dflow-sh/kube-poc/packages/dflow/api/v1/response"
	"github.com/dflow-sh/kube-poc/packages/dflow/cli/server/requestctx"
	"github.com/gin-gonic/gin"

	apierrors "github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/errors"
)

func Recovery(c *gin.Context) {
	stackWriter := &bytes.Buffer{}

	gin.CustomRecoveryWithWriter(stackWriter, func(c *gin.Context, anyerr any) {
		ctx := c.Request.Context()
		reqID := requestctx.ID(ctx)
		logger := requestctx.Logger(ctx).With("component", "RecoveryMiddleware")

		err, ok := anyerr.(error)
		if !ok {
			err = fmt.Errorf("unknown error type occurred [%T]", anyerr)
		}

		logger.Errorw("recovered from panic",
			"error", err,
			"stack", stackWriter.String(),
		)

		// we don't want to expose internal details to the client
		errMsg := fmt.Sprintf("something bad happened [request ID: %s]", reqID)
		response.Error(c, apierrors.NewInternalError(errMsg))

		c.Abort()
	})(c)
}
