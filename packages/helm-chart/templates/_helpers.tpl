{{/*
Expand the name of the chart.
*/}}
{{- define "dflow.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "dflow.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "dflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "dflow.labels" -}}
helm.sh/chart: {{ include "dflow.chart" . }}
app.kubernetes.io/component: dflow
app.kubernetes.io/instance: default
app.kubernetes.io/name: dflow-server
app.kubernetes.io/part-of: dflow
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.image.dflow.tag }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "dflow.selectorLabels" -}}
app.kubernetes.io/component: dflow-server
app.kubernetes.io/instance: default
app.kubernetes.io/name: dflow-server
app.kubernetes.io/part-of: dflow
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "dflow.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dflow.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}


{{/*
imageRef prints repository@sha256:digest when digest is set, otherwise
registry + repository:tag. A digest pin is absolute and is not prefixed.
*/}}
{{- define "dflow.imageRef" -}}
{{- $digest := .digest | default "" | toString -}}
{{- $repo := .repository | toString -}}
{{- if $digest -}}
{{- if not (hasPrefix "sha256:" $digest) -}}
{{- $digest = printf "sha256:%s" $digest -}}
{{- end -}}
{{- printf "%s@%s" $repo $digest -}}
{{- else -}}
{{- $reg := .registry | default "" | toString -}}
{{- if and $reg (not (hasSuffix "/" $reg)) -}}
{{- $reg = printf "%s/" $reg -}}
{{- end -}}
{{- printf "%s%s:%s" $reg $repo (.tag | toString) -}}
{{- end -}}
{{- end -}}

{{/*
URL prefix for container images to be compatible with Rancher
*/}}
{{- define "registry-url" -}}
{{- if .Values.global.cattle.systemDefaultRegistry -}}
{{ trimSuffix "/" .Values.global.cattle.systemDefaultRegistry }}/
{{- end -}}
{{- end -}}

{{/*
URL of the registry dflow uses to store workload images
*/}}
{{- define "dflow.registry-url" -}}
{{- if .Values.containerregistry.enabled -}}
{{-   printf "registry.%s.svc.cluster.local:5000" .Release.Namespace }}
{{- else -}}
{{-   .Values.global.registryURL }}
{{- end -}}
{{- end -}}

{{/*
URL of the SeaweedFS S3 endpoint dflow installed
*/}}
{{- define "dflow.seaweedfs-url" -}}
{{- if .Values.seaweedfs.enabled -}}
{{-   printf "%s-s3.%s.svc.cluster.local:%d" (default "seaweedfs" .Values.seaweedfs.fullnameOverride) .Release.Namespace (int (default 8333 .Values.seaweedfs.s3.port)) }}
{{- else -}}
{{-  .Values.s3.endpoint }}
{{- end -}}
{{- end -}}

{{/*
Host name of the SeaweedFS S3 service dflow installed
*/}}
{{- define "dflow.seaweedfs-hostname" -}}
{{- printf "%s-s3.%s.svc.cluster.local" (default "seaweedfs" .Values.seaweedfs.fullnameOverride) .Release.Namespace }}
{{- end -}}

{{/*
PVC cleanup hooks for bitnami helm chart based catalog services
# https://github.com/dflow-sh/kube-poc/packages/dflow/issues/1386
# https://docs.bitnami.com/kubernetes/apps/aspnet-core/administration/deploy-extra-resources/
*/}}
{{- define "dflow.catalog-service-values" -}}
{{ printf `
extraDeploy:
  - |
    # Create a service account, role and binding to allow to list, get and
    # delete PVCs. It should be used by the job below.

    # To ensure the resources are deleted, use this annotation:
    #
    # annotations:
    #  "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded

    # https://helm.sh/docs/topics/charts_hooks/#hook-resources-are-not-managed-with-corresponding-releases
    # https://helm.sh/docs/topics/charts_hooks/#hook-deletion-policies

    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: "pvc-deleter-{{ .Release.Name }}"
      namespace: {{ .Release.Namespace }}
      annotations:
        "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
        "helm.sh/hook": post-delete
        "helm.sh/hook-weight": "-6"

    ---
    apiVersion: {{ include "common.capabilities.rbac.apiVersion" . }}
    kind: Role
    metadata:
      name: "pvc-deleter-{{ .Release.Name }}"
      namespace: {{ .Release.Namespace }}
      annotations:
        "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
        "helm.sh/hook": post-delete
        "helm.sh/hook-weight": "-6"
    rules:
      - apiGroups:
          - ""
        resources:
          - persistentvolumeclaims
        verbs:
          - get
          - delete
          - list

    ---
    kind: RoleBinding
    apiVersion: {{ include "common.capabilities.rbac.apiVersion" . }}
    metadata:
      name: "pvc-deleter-{{ .Release.Name }}"
      namespace: {{ .Release.Namespace }}
      annotations:
        "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
        "helm.sh/hook": post-delete
        "helm.sh/hook-weight": "-5"
    subjects:
      - kind: ServiceAccount
        name: "pvc-deleter-{{ .Release.Name }}"
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: "pvc-deleter-{{ .Release.Name }}"

    ---
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: "pvc-deleter-{{ .Release.Name }}"
      labels:
        app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
        app.kubernetes.io/instance: {{ .Release.Name | quote }}
        app.kubernetes.io/version: {{ .Chart.AppVersion }}
        helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version }}"
      annotations:
        # This is what defines this resource as a hook. Without this line, the
        # job is considered part of the release.
        "helm.sh/hook": post-delete
        "helm.sh/hook-weight": "-4"
        "helm.sh/hook-delete-policy": hook-succeeded
    spec:
      template:
        metadata:
          name: "pvc-deleter-{{ .Release.Name }}"
          labels:
            app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
            app.kubernetes.io/instance: {{ .Release.Name | quote }}
            helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version }}"
        spec:
          restartPolicy: Never
          serviceAccountName: "pvc-deleter-{{ .Release.Name }}"
          containers:
          - name: post-install-job
            image: "%s"
            command: ["kubectl", "delete", "pvc", "-n", "{{ .Release.Namespace }}", "-l", "app.kubernetes.io/instance={{ .Release.Name }}"]
` (include "dflow.imageRef" .Values.image.kubectl) | indent 4}}
{{- end -}}

{{/*
Removes characters that are invalid for kubernetes resource names from the
given string
*/}}
{{- define "dflow-name-sanitize" -}}
{{ regexReplaceAll "[^-a-z0-9]*" . "" }}
{{- end }}

{{/*
Resource name sanitization and truncation.
- Always suffix the sha1sum (40 characters long)
- Always add an "r" prefix to make sure we don't have leading digits
- The rest of the characters up to 63 are the original string with invalid
character removed.
*/}}
{{- define "dflow-truncate" -}}
{{ print "r" (trunc 21 (include "dflow-name-sanitize" .)) "-" (sha1sum .) }}
{{- end }}


{{/*
Return the appropriately configured hostname for dFlow.
Prioritizes ingress override in the case that both ingress & gateway overrides are enabled.
Affects fallback ENV variables on dFlow UI
 - ALLOWED_ORIGINS unless provided .Values.dflowUI.allowedOrigins
 - DFLOW_UI_URL   unless provided .Values.dflowUI.uiURL
Affects Dex config's configured redirectURIs unless provided .Values.dex.ui.redirectURI
*/}}
{{- define "dflow-hostname" -}}
{{- if and .Values.ingress .Values.ingress.enabled (hasKey .Values.ingress "hostnameOverride") .Values.ingress.hostnameOverride -}}
  {{- .Values.ingress.hostnameOverride -}}
{{- else if and .Values.gateway .Values.gateway.enabled (hasKey .Values.gateway "hostnameOverride") .Values.gateway.hostnameOverride -}}
  {{- .Values.gateway.hostnameOverride -}}
{{- else -}}
  {{- printf "%s.%s" "dflow" .Values.global.domain -}}
{{- end -}}
{{- end }}


{{/*
Return the appropriately configured ingress hostname for dFlow
*/}}
{{- define "dflow-ingress-hostname" -}}
{{- if and .Values.ingress .Values.ingress.enabled (hasKey .Values.ingress "hostnameOverride") .Values.ingress.hostnameOverride -}}
  {{- .Values.ingress.hostnameOverride -}}
{{- else -}}
  {{- printf "%s.%s" "dflow" .Values.global.domain -}}
{{- end -}}
{{- end }}


{{/*
Return the appropriately configured gateway hostname for dFlow
*/}}
{{- define "dflow-gateway-hostname" -}}
{{- if and .Values.gateway .Values.gateway.enabled (hasKey .Values.gateway "hostnameOverride") .Values.gateway.hostnameOverride -}}
  {{- .Values.gateway.hostnameOverride -}}
{{- else -}}
  {{- printf "%s.%s" "dflow" .Values.global.domain -}}
{{- end -}}
{{- end }}


{{/*
Return the appropriately configured hostname for Dex
Prioritizes ingress override in the case that both ingress & gateway overrides are enabled.
Affects fallback ENV variables on dFlow UI
 - DFLOW_DEX_ISSUER
*/}}
{{- define "dflow-dex-hostname" -}}
{{- if and .Values.ingress .Values.ingress.enabled (hasKey .Values.ingress "dexHostnameOverride") .Values.ingress.dexHostnameOverride -}}
  {{- .Values.ingress.dexHostnameOverride -}}
{{- else if and .Values.gateway .Values.gateway.enabled (hasKey .Values.gateway "dexHostnameOverride") .Values.gateway.dexHostnameOverride -}}
  {{- .Values.gateway.dexHostnameOverride -}}
{{- else -}}
  {{- printf "%s.%s" "auth" .Values.global.domain -}}
{{- end -}}
{{- end }}


{{/*
Return the configured Issuer URL for Dex
*/}}
{{- define "dflow-dex-issuer" -}}
{{- if .Values.dex.issuer.port -}}
 {{- printf "https://%s:%s" (include "dflow-dex-hostname" .) (toString .Values.dex.issuer.port) -}}
{{- else -}}
 {{- printf "https://%s" (include "dflow-dex-hostname" .) -}}
{{- end -}}
{{- end }}
