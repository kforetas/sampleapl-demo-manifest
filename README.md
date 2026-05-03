# sampleapl-demo-manifest
## ArgoCD資源の反映
oc apply -f https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main/project.yaml
oc apply -f https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main/app-of-apps/app-of-apps.yaml
## Tekton資源の反映
oc apply -f https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main/app-of-apps/pipeline-app.yaml