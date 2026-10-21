package helm

import (
	"context"
	"encoding/base64"
	"errors"

	"github.com/dflow-sh/kube-poc/packages/dflow/helpers"
	"github.com/dflow-sh/kube-poc/packages/dflow/helpers/kubernetes"
	"github.com/dflow-sh/kube-poc/packages/dflow/registry"
	"github.com/dflow-sh/kube-poc/packages/dflow/pkg/api/core/v1/models"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/viper"
	"go.uber.org/zap"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

var _ = Describe("OCI helpers", func() {

	Describe("ociHostname", func() {
		DescribeTable("extracts the host",
			func(input, expected string) {
				Expect(ociHostname(input)).To(Equal(expected))
			},
			Entry("oci url with path", "oci://registry.example.com:5000/charts", "registry.example.com:5000"),
			Entry("oci url with trailing slash", "oci://registry.example.com/charts/", "registry.example.com"),
			Entry("oci url without path", "oci://registry.example.com", "registry.example.com"),
			Entry("bare host and port", "registry.example.com:5000", "registry.example.com:5000"),
			Entry("https url", "https://registry.example.com/v2", "registry.example.com"),
			Entry("http url", "http://127.0.0.1:30500", "127.0.0.1:30500"),
		)
	})

	Describe("registry.IsInClusterHost", func() {
		DescribeTable("recognizes registries running in the cluster",
			func(hostname string, expected bool) {
				Expect(registry.IsInClusterHost(hostname)).To(Equal(expected))
			},
			Entry("service address", "registry.dflow.svc.cluster.local:5000", true),
			Entry("node port", "127.0.0.1:30500", true),
			Entry("localhost", "localhost:5000", true),
			Entry("external registry", "registry.example.com", false),
			Entry("public registry", "ghcr.io", false),
			Entry("loopback ipv6", "[::1]:5000", true),
			Entry("loopback without port", "127.0.0.1", true),
			Entry("upper case service address", "Registry.dFlow.SVC.Cluster.Local:5000", true),
			Entry("service address as fqdn", "registry.dflow.svc.cluster.local.:5000", true),
			Entry("cluster domain only as prefix", "registry.svc.cluster.local.example.com", false),
			Entry("cluster domain in the middle, with port", "registry.svc.cluster.local.example.com:5000", false),
			Entry("localhost only as prefix", "localhost.example.com:5000", false),
			Entry("localhost only as suffix", "evil-localhost:5000", false),
			Entry("loopback address only as prefix", "127.0.0.1.example.com", false),
			Entry("loopback address only as suffix", "example.127.0.0.1", false),
		)
	})

	Describe("splitChartVersion", func() {
		DescribeTable("splits name and version",
			func(input, name, version string) {
				n, v := splitChartVersion(input)
				Expect(n).To(Equal(name))
				Expect(v).To(Equal(version))
			},
			Entry("with version", "dflow-application:0.1.26", "dflow-application", "0.1.26"),
			Entry("without version", "dflow-application", "dflow-application", ""),
			Entry("empty version", "dflow-application:", "dflow-application", ""),
			Entry("only the first colon splits", "chart:1.0.0-rc:1", "chart", "1.0.0-rc:1"),
		)
	})

	Describe("ociChartRef", func() {
		It("joins repository and chart", func() {
			Expect(ociChartRef("oci://registry.example.com/charts", "foo")).
				To(Equal("oci://registry.example.com/charts/foo"))
		})
		It("does not double the slash", func() {
			Expect(ociChartRef("oci://registry.example.com/charts/", "foo")).
				To(Equal("oci://registry.example.com/charts/foo"))
		})
	})

	Describe("registry credentials", func() {
		const (
			dflowNamespace = "dflow"
			internalURL     = "registry.dflow.svc.cluster.local:5000"
		)

		var (
			ctx        context.Context
			fakeClient *fake.Clientset
			cluster    *kubernetes.Cluster
		)

		credsSecret := func(dockerConfigJSON string) *corev1.Secret {
			return &corev1.Secret{
				ObjectMeta: metav1.ObjectMeta{
					Name:      registry.CredentialsSecretName,
					Namespace: dflowNamespace,
				},
				Data: map[string][]byte{".dockerconfigjson": []byte(dockerConfigJSON)},
				Type: corev1.SecretTypeDockerConfigJson,
			}
		}

		internalOnlySecret := func() *corev1.Secret {
			return credsSecret(`{"auths":{"` + internalURL + `":{"username":"admin","password":"changeme"}}}`)
		}

		failSecretReads := func() {
			fakeClient.PrependReactor("get", "secrets",
				func(k8stesting.Action) (bool, runtime.Object, error) {
					return true, nil, errors.New("api server unavailable")
				})
		}

		BeforeEach(func() {
			ctx = context.Background()
			fakeClient = fake.NewSimpleClientset()
			cluster = &kubernetes.Cluster{Kubectl: fakeClient}

			oldNamespace := viper.GetString("namespace")
			viper.Set("namespace", dflowNamespace)
			DeferCleanup(func() { viper.Set("namespace", oldNamespace) })

			oldLogger := helpers.Logger
			helpers.Logger = zap.NewNop().Sugar()
			DeferCleanup(func() { helpers.Logger = oldLogger })
		})

		Describe("internalRegistryCredentials", func() {
			It("returns the credentials for dFlow's own registry", func() {
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx, credsSecret(
					`{"auths":{"`+internalURL+`":{"username":"admin","password":"changeme"},`+
						`"127.0.0.1:30500":{"username":"other","password":"other"}}}`),
					metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				creds, err := internalRegistryCredentials(ctx, cluster, "oci://"+internalURL+"/dflow-charts")
				Expect(err).ToNot(HaveOccurred())
				Expect(creds).ToNot(BeNil())
				Expect(creds.Hostname).To(Equal(internalURL))
				Expect(creds.Username).To(Equal("admin"))
				Expect(creds.Password).To(Equal("changeme"))
				Expect(creds.Insecure).To(BeTrue())
			})

			It("verifies the certificate of a registry outside of the cluster", func() {
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx, credsSecret(
					`{"auths":{"registry.example.com":{"username":"admin","password":"changeme"}}}`),
					metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				creds, err := internalRegistryCredentials(ctx, cluster, "oci://registry.example.com/dflow-charts")
				Expect(err).ToNot(HaveOccurred())
				Expect(creds).ToNot(BeNil())
				Expect(creds.Insecure).To(BeFalse())
			})

			It("decodes credentials given in the auth field", func() {
				auth := base64.StdEncoding.EncodeToString([]byte("admin:changeme"))
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx,
					credsSecret(`{"auths":{"`+internalURL+`":{"auth":"`+auth+`"}}}`), metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				creds, err := internalRegistryCredentials(ctx, cluster, "oci://"+internalURL+"/dflow-charts")
				Expect(err).ToNot(HaveOccurred())
				Expect(creds).ToNot(BeNil())
				Expect(creds.Username).To(Equal("admin"))
				Expect(creds.Password).To(Equal("changeme"))
			})

			It("returns nothing for a registry which is not dFlow's own", func() {
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx, internalOnlySecret(), metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				creds, err := internalRegistryCredentials(ctx, cluster, "oci://ghcr.io/dflow-sh/charts")
				Expect(err).ToNot(HaveOccurred())
				Expect(creds).To(BeNil())
			})

			It("returns nothing, and no error, when there is no registry secret", func() {
				creds, err := internalRegistryCredentials(ctx, cluster, "oci://"+internalURL+"/dflow-charts")
				Expect(err).ToNot(HaveOccurred())
				Expect(creds).To(BeNil())
			})

			It("reports other failures to read the secret", func() {
				failSecretReads()

				creds, err := internalRegistryCredentials(ctx, cluster, "oci://"+internalURL+"/dflow-charts")
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("api server unavailable"))
				Expect(creds).To(BeNil())
			})

			It("reports a broken registry secret", func() {
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx,
					credsSecret("this is not json"), metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				_, err = internalRegistryCredentials(ctx, cluster, "oci://"+internalURL+"/dflow-charts")
				Expect(err).To(HaveOccurred())
			})
		})

		Describe("getChartReference for OCI charts", func() {
			// The zero value client is never used for a registry without credentials. Any attempt
			// to login with it fails, which is what the specs use to detect such an attempt.
			client := &SynchronizedClient{}

			appChart := func(repo, chart string) *models.AppChartFull {
				return &models.AppChartFull{
					AppChart: models.AppChart{HelmRepo: repo, HelmChart: chart},
				}
			}

			It("builds the reference and version for an external registry, without login", func() {
				// Credentials for dFlow's own registry exist, but must not be used for
				// any other registry.
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx, internalOnlySecret(), metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				ref, version, err := getChartReference(ctx, cluster, client,
					appChart("oci://ghcr.io/dflow-sh/charts/", "dflow-application:0.1.26"))
				Expect(err).ToNot(HaveOccurred())
				Expect(ref).To(Equal("oci://ghcr.io/dflow-sh/charts/dflow-application"))
				Expect(version).To(Equal("0.1.26"))
			})

			It("accepts a chart without version", func() {
				ref, version, err := getChartReference(ctx, cluster, client,
					appChart("oci://ghcr.io/dflow-sh/charts", "dflow-application"))
				Expect(err).ToNot(HaveOccurred())
				Expect(ref).To(Equal("oci://ghcr.io/dflow-sh/charts/dflow-application"))
				Expect(version).To(BeEmpty())
			})

			It("tries to login to dFlow's own registry", func() {
				_, err := fakeClient.CoreV1().Secrets(dflowNamespace).Create(ctx, internalOnlySecret(), metav1.CreateOptions{})
				Expect(err).ToNot(HaveOccurred())

				_, _, err = getChartReference(ctx, cluster, client,
					appChart("oci://"+internalURL+"/dflow-charts", "foo:1.0.0"))
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("logging into the OCI chart registry"))
			})

			It("fails when the registry secret cannot be read", func() {
				failSecretReads()

				_, _, err := getChartReference(ctx, cluster, client,
					appChart("oci://"+internalURL+"/dflow-charts", "foo:1.0.0"))
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("api server unavailable"))
			})
		})
	})
})
