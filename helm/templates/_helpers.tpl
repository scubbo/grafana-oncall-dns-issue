{{- define "localIngressName" -}}
{{- printf "%s.%s" .Values.nameOverride .Values.dnsLocalDomain }}
{{- end }}

{{- define "publicIngressName" -}}
{{- printf "%s.%s" .Values.nameOverride .Values.dnsPublicDomain }}
{{- end }}

{{- define "serviceName" -}}
{{- printf "%s-service" .Values.nameOverride }}
{{- end }}