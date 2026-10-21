package domain

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("AppDefaultRoute", func() {
	It("uses APPS_DOMAIN when it is set", func() {
		GinkgoT().Setenv("APPS_DOMAIN", "apps.dflow.sh")
		route, err := AppDefaultRoute(context.Background(), "hello", "sample")
		Expect(err).ToNot(HaveOccurred())
		Expect(route).To(Equal("hello.apps.dflow.sh"))
	})
})
