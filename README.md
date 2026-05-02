# sampleapl-demo-manifest
## ArgoCD資源の反映
oc apply -f https://github.com/kforetas/sampleapl-demo-manifest/main/app-of-apps/app-of-apps.yaml
## Tekton資源の反映
oc apply -f https://github.com/kforetas/sampleapl-demo-manifest/main/app-of-apps/pipeline-app.yaml