# sampleapl-demo-manifest
## ArgoCD資源の反映
oc apply -f https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main/app-of-apps/app-of-apps.yaml
## Tekton資源の反映
oc apply -f https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main/app-of-apps/namespace-tekton-app.yaml
oc apply -f https://raw.githubusercontent.com/kforetas/sampleapl-demo-manifest/refs/heads/main/app-of-apps/pipeline-app.yaml

## パッチ適用デモ (patch-demo-pipeline)
①脆弱性スキャン → ②最新ベースイメージで再ビルド → ③dev へリリース → ④Playwright で画面テスト → ⑤再スキャン → ⑥Before/After レポート

アプリのソースは dev で稼働中と同じコミットを使い、ベースイメージ (ubi9/python-39) だけを最新の digest に差し替えて再ビルドする。

### 事前準備: 脆弱な状態を作る
古いベースイメージのタグを確認する
skopeo list-tags docker://registry.access.redhat.com/ubi9/python-39

古いタグでビルドして dev にデプロイする（⑤のゲートは無効化）
PATCH_URL=https://$(oc get route el-patch-demo-listener -n tekton-demo -o jsonpath='{.spec.host}')
curl -k -X POST $PATCH_URL -H 'Content-Type: application/json' -d '{"baseImageTag":"<古いタグ>","failOnFixable":"false"}'

### デモ本番: 最新ベースイメージでパッチ適用
curl -k -X POST $PATCH_URL -H 'Content-Type: application/json' -d '{}'

### 補足
- 結果は PipelineRun の report タスクのログに Before/After の比較表として出力される
- source リポジトリの main に push すると innerloop が dev のタグを上書きするため、デモ中は push しない
- ArgoCD への即時反映には patch-demo-rbac.yaml の権限を使う（権限がない場合はポーリング (最大3分) で反映される）
