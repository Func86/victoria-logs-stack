{{- define "victoria-logs-stack.commonLabels" -}}
app.kubernetes.io/part-of: victoria-logs
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "victoria-logs-stack.scheduling" -}}
{{- with .Values.scheduling.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.scheduling.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
