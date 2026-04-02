{{/*
Expand the name of the chart.
*/}}
{{- define "mihari-collector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mihari-collector.fullname" -}}
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
{{- define "mihari-collector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mihari-collector.labels" -}}
helm.sh/chart: {{ include "mihari-collector.chart" . }}
{{ include "mihari-collector.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mihari-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mihari-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "mihari-collector.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mihari-collector.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Collector image
*/}}
{{- define "mihari-collector.image" -}}
{{- if eq .Values.collector "otel" }}
{{- printf "%s:%s" .Values.image.otel.repository .Values.image.otel.tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.vector.repository .Values.image.vector.tag }}
{{- end }}
{{- end }}

{{/*
Collector image pull policy
*/}}
{{- define "mihari-collector.imagePullPolicy" -}}
{{- if eq .Values.collector "otel" }}
{{- .Values.image.otel.pullPolicy }}
{{- else }}
{{- .Values.image.vector.pullPolicy }}
{{- end }}
{{- end }}
