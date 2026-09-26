#!/usr/bin/env bash
# ROSA 上にコンテナ CI/CD ＋パッチ適用デモ環境を構築する
#
# 前提: Bastion で cluster-admin として oc login 済みであること
# 使い方:
#   git clone https://github.com/kforetas/sampleapl-demo-manifest.git
#   cd sampleapl-demo-manifest
#   bash scripts/setup-demo.sh
#
# 認証情報は環境変数で渡すか、実行中の入力プロンプトで入力する（入力内容は表示されない）
#   GITHUB_USER / GITHUB_TOKEN       : manifest リポジトリへ push できる GitHub の PAT
#   DOCKERHUB_USER / DOCKERHUB_TOKEN : Docker Hub のアクセストークン
#
# 何度実行しても同じ状態になるように作ってある（途中で失敗したら再実行してよい）
set -euo pipefail

RAW=https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main
GITHUB_USER=${GITHUB_USER:-kforetas}
DOCKERHUB_USER=${DOCKERHUB_USER:-rhnconsultingkemori}

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# 条件 (bash の式) が成立するまで待つ
wait_for() {
  local desc=$1 timeout=$2 cond=$3
  local end=$((SECONDS + timeout))
  printf '待機中: %s ' "$desc"
  until bash -c "$cond" >/dev/null 2>&1; do
    ((SECONDS >= end)) && { echo; die "タイムアウト: $desc"; }
    printf '.'
    sleep 10
  done
  echo " OK"
}

csv_succeeded() { # namespace csv名の接頭辞
  echo "oc get csv -n $1 -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{\"\\n\"}{end}' | grep '^$2' | grep -q ' Succeeded$'"
}

app_healthy() { # ArgoCD Application 名
  echo "[ \"\$(oc get applications.argoproj.io $1 -n openshift-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}')\" = Synced/Healthy ]"
}

# ------------------------------------------------------------------ 0. 前提確認
log "0. 前提確認"
oc whoami >/dev/null 2>&1 || die "oc login してから実行してください"
[ "$(oc auth can-i '*' '*' --all-namespaces)" = yes ] || die "cluster-admin 権限が必要です"
oc get storageclass gp3-csi >/dev/null || die "StorageClass gp3-csi がありません（マニフェストの storageClassName を修正してください）"
echo "ユーザー: $(oc whoami) / クラスタ: $(oc whoami --show-server)"

if [ -z "${GITHUB_TOKEN:-}" ]; then read -rsp "GitHub ($GITHUB_USER) のトークン: " GITHUB_TOKEN; echo; fi
if [ -z "${DOCKERHUB_TOKEN:-}" ]; then read -rsp "Docker Hub ($DOCKERHUB_USER) のトークン: " DOCKERHUB_TOKEN; echo; fi
[ -n "$GITHUB_TOKEN" ] && [ -n "$DOCKERHUB_TOKEN" ] || die "トークンが入力されていません"

# ------------------------------------------------------------------ 1. Operator
log "1. OpenShift Pipelines / OpenShift GitOps の Operator をインストール"
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
wait_for "Pipelines Operator" 900 "$(csv_succeeded openshift-operators openshift-pipelines-operator-rh)"
wait_for "GitOps Operator" 900 "$(csv_succeeded openshift-gitops-operator openshift-gitops-operator)"
wait_for "TektonConfig Ready" 900 "oc get tektonconfig config -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
wait_for "共通 Task (git-clone / buildah / git-cli)" 600 "oc get task git-clone buildah git-cli -n openshift-pipelines"
wait_for "ArgoCD (openshift-gitops)" 900 "oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.availableReplicas}' | grep -q '^[1-9]'"

# ------------------------------------------------------------------ 2. ArgoCD の権限
log "2. ArgoCD に権限を付与"
oc adm policy add-cluster-role-to-user edit -z openshift-gitops-argocd-application-controller -n openshift-gitops

# ------------------------------------------------------------------ 3. アプリ環境
log "3. アプリ環境 (dev / itst-1〜3 / prod) と tekton-demo Namespace を作成"
oc apply -f "$RAW/app-of-apps/app-of-apps.yaml"
oc apply -f "$RAW/app-of-apps/namespace-tekton-app.yaml"
for app in root-app tekton-namespace-app deploy-sampleapl-demo-dev; do
  wait_for "ArgoCD Application $app" 600 "$(app_healthy $app)"
done

# ------------------------------------------------------------------ 4. パイプライン用の認証情報
log "4. パイプライン用の Secret を作成 (tekton-demo)"
oc create secret generic github-auth -n tekton-demo --type=kubernetes.io/basic-auth \
  --from-literal=username="$GITHUB_USER" --from-file=password=<(printf '%s' "$GITHUB_TOKEN") \
  --dry-run=client -o yaml | oc apply -f -
oc annotate secret github-auth -n tekton-demo tekton.dev/git-0=https://github.com --overwrite
oc create secret generic dockerhub-auth -n tekton-demo --type=kubernetes.io/basic-auth \
  --from-literal=username="$DOCKERHUB_USER" --from-file=password=<(printf '%s' "$DOCKERHUB_TOKEN") \
  --dry-run=client -o yaml | oc apply -f -
oc annotate secret dockerhub-auth -n tekton-demo tekton.dev/docker-0=https://index.docker.io/v1/ --overwrite
unset GITHUB_TOKEN DOCKERHUB_TOKEN

wait_for "ServiceAccount pipeline" 300 "oc get sa pipeline -n tekton-demo"
oc secrets link pipeline github-auth dockerhub-auth -n tekton-demo
oc adm policy add-scc-to-user privileged -z pipeline -n tekton-demo
oc adm policy add-role-to-user edit -z pipeline -n tekton-demo

# ------------------------------------------------------------------ 5. パイプライン
log "5. パイプライン (Tekton) をデプロイ"
# demo-dev への RoleBinding を含むため、demo-dev ができてから適用する
oc apply -f "$RAW/app-of-apps/pipeline-app.yaml"
wait_for "ArgoCD Application pipeline-app" 600 "$(app_healthy pipeline-app)"
wait_for "EventListener" 300 "oc get deployment el-sampleapl-listener el-patch-demo-listener -n tekton-demo -o jsonpath='{.items[*].status.availableReplicas}' | grep -Eq '^[1-9]+ [1-9]+$'"

# ------------------------------------------------------------------ 6. パッチ管理コンソール
log "6. パッチ管理コンソールと ITSM モックをデプロイ"
oc apply -f "$RAW/app-of-apps/patch-console-app.yaml"
wait_for "クラスタ内ビルド" 900 "oc get builds -n patch-console -o jsonpath='{.items[*].status.phase}' | grep -q Complete"
wait_for "パッチ管理コンソール" 600 "oc get deployment patch-console itsm-mock -n patch-console -o jsonpath='{.items[*].status.availableReplicas}' | grep -Eq '^[1-9]+ [1-9]+$'"
wait_for "ArgoCD Application patch-console-app" 600 "$(app_healthy patch-console-app)"

# ------------------------------------------------------------------ 7. 結果
DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
log "7. セットアップ完了"
cat <<EOF

■ GitHub Webhook（クラスタごとに URL が変わるので毎回更新する）
  sampleapl-demo-manifest → Settings → Webhooks
    Payload URL : https://openshift-gitops-server-openshift-gitops.${DOMAIN}/api/webhook
    Content type: application/json
  sampleapl-demo → Settings → Webhooks
    Payload URL : http://el-sampleapl-listener-tekton-demo.${DOMAIN}
    Content type: application/json

■ デモで使う URL
  パッチ管理コンソール : https://patch-console-patch-console.${DOMAIN}
  ITSM モック          : https://itsm-mock-patch-console.${DOMAIN}
  OpenShift コンソール : https://console-openshift-console.${DOMAIN}
  ArgoCD               : https://openshift-gitops-server-openshift-gitops.${DOMAIN}
  dev アプリ           : https://sampleapl-demo-demo-dev.${DOMAIN}

■ 次の作業
  パッチ管理コンソールで「デモ準備を実行」を押し、完了（約10分）を待つ
EOF
