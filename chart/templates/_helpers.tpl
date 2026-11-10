{{/* nodeSelector for an app's node role (server|worker). Usage: include "homelab.nodeSelector" (list $ "worker") */}}
{{- define "homelab.nodeSelector" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- if $role }}
nodeSelector:
  kubernetes.io/hostname: {{ (index $root.Values.nodes $role).name }}
{{- end }}
{{- end }}

{{- define "homelab.tz" -}}
- name: TZ
  value: {{ .Values.timezone }}
{{- end }}

{{/* PUID/PGID/TZ for linuxserver.io images. */}}
{{- define "homelab.linuxserverEnv" -}}
- name: PUID
  value: {{ .Values.admin.uid | quote }}
- name: PGID
  value: {{ .Values.admin.gid | quote }}
{{ include "homelab.tz" . }}
{{- end }}

{{- define "homelab.runAsAdmin" -}}
runAsUser: {{ .Values.admin.uid }}
runAsGroup: {{ .Values.admin.gid }}
{{- end }}

{{/* hostPath volume under paths.config. Usage: include "homelab.configVolume" (list $ "name" "sub/path") */}}
{{- define "homelab.configVolume" -}}
{{- $root := index . 0 -}}
- name: {{ index . 1 }}
  hostPath:
    path: {{ $root.Values.paths.config }}/{{ index . 2 }}
    type: Directory
{{- end }}

{{/*
gluetun VPN sidecar (native sidecar init container). The pod's other containers
share its network, so its firewall is the kill switch.
Usage: include "homelab.gluetun" (dict "root" $ "image" "..." "secret" "..." "env" (list ...))
*/}}
{{- define "homelab.gluetun" -}}
- name: gluetun
  image: {{ .image }}
  restartPolicy: Always
  # A restarted container inherits stale policy-routing rules and then fails
  # with "adding IPv6 rule: file exists".
  command:
    - /bin/sh
    - -c
    - |
      while ip rule del table 51820 2>/dev/null; do :; done
      while ip -6 rule del table 51820 2>/dev/null; do :; done
      exec /gluetun-entrypoint
  securityContext:
    capabilities:
      add: ["NET_ADMIN"]
  envFrom:
    - secretRef:
        name: {{ .secret }}
  env:
    {{- include "homelab.tz" .root | nindent 4 }}
    - name: VPN_TYPE
      value: wireguard
    {{- with .env }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  startupProbe:
    exec:
      command: ["/gluetun-entrypoint", "healthcheck"]
    periodSeconds: 5
    timeoutSeconds: 5
    failureThreshold: 60
  livenessProbe:
    exec:
      command: ["/gluetun-entrypoint", "healthcheck"]
    periodSeconds: 60
    timeoutSeconds: 5
    failureThreshold: 3
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      memory: 128Mi
  volumeMounts:
    - name: tun
      mountPath: /dev/net/tun
{{- end }}

{{- define "homelab.tunVolume" -}}
- name: tun
  hostPath:
    path: /dev/net/tun
    type: CharDevice
{{- end }}

{{/* Namespaces and data volumes survive `helm uninstall`. */}}
{{- define "homelab.keepAnnotation" -}}
annotations:
  helm.sh/resource-policy: keep
{{- end }}
