# パッチ適用デモ 手順書（ROSA 環境構築〜デモ実行）

新しく払い出した ROSA クラスタに、コンテナ CI/CD とパッチ適用デモの環境を作り、デモを実行するまでの手順です。

| フェーズ | 内容 | 所要時間の目安 |
|---|---|---|
| [1. 環境構築](#1-環境構築) | Operator のインストールからコンソールのデプロイまで（スクリプトで自動化） | 約 15〜20 分 |
| [2. GitHub Webhook の更新](#2-github-webhook-の更新) | クラスタごとに変わる URL を GitHub に設定 | 約 3 分 |
| [3. デモ準備](#3-デモ準備) | dev を「古いベースイメージ」の状態にする | 約 10 分 |
| [4. デモ実行](#4-デモ実行) | ①可視化 → ②パッチ適用 → ③結果確認 | 約 10 分 |

## デモ環境の全体像

```
 パッチ管理コンソール ──②チケット起票──▶ ITSM モック（ServiceNow 想定）
        │                                      ▲
        │②PipelineRun 起動                     │③チケットをクローズ
        ▼                                      │
 patch-demo-pipeline: ①スキャン → ②最新ベースで再ビルド → ③dev リリース
                       → ④Playwright 画面テスト → ⑤再スキャン → ⑥レポート / 通知
                                   │
                                   ▼ マニフェスト更新 (GitOps)
                            ArgoCD → dev 環境 (demo-dev)
```

| リポジトリ | 内容 |
|---|---|
| [sampleapl-demo](https://github.com/kforetas/sampleapl-demo) | デモ対象のアプリ（Flask）と Playwright テスト、Trivy の除外設定 |
| [sampleapl-demo-manifest](https://github.com/kforetas/sampleapl-demo-manifest) | ArgoCD / Tekton / コンソールのマニフェスト、本手順書、セットアップスクリプト |
| [patch-demo-console](https://github.com/kforetas/patch-demo-console) | パッチ管理コンソールと ITSM モックのソース |

---

## 0. 事前に用意するもの

- ROSA の払い出し情報（Bastion の SSH 接続先とパスワード、`cluster-admin` のパスワード、API の URL）
- GitHub `kforetas` の Personal Access Token（`sampleapl-demo-manifest` に push できること）
- Docker Hub `rhnconsultingkemori` のアクセストークン

トークン類はコマンドラインに直接書かないでください。シェルの履歴に残ります。セットアップスクリプトは入力プロンプトで受け取ります。

---

## 1. 環境構築

### 1-1. Bastion にログインしてクラスタに接続

```bash
ssh rosa@<Bastion のホスト名>
oc login <API の URL> -u cluster-admin     # パスワードは入力プロンプトで入れる
oc whoami                                 # cluster-admin と表示されること
```

### 1-2. セットアップスクリプトを実行

```bash
git clone https://github.com/kforetas/sampleapl-demo-manifest.git
cd sampleapl-demo-manifest
bash scripts/setup-demo.sh
```

GitHub と Docker Hub のトークンを聞かれるので入力します（入力しても画面には表示されません）。

スクリプトは次の順に処理します。途中で失敗しても、**同じコマンドで再実行すれば続きから同じ状態に揃います**。

| # | 内容 | 補足 |
|---|---|---|
| 0 | 前提確認 | cluster-admin であること、StorageClass `gp3-csi` があること |
| 1 | OpenShift Pipelines / GitOps の Operator をインストール | 完了まで数分。共通 Task（git-clone / buildah / git-cli）と ArgoCD の起動まで待つ |
| 2 | ArgoCD に `edit` 権限を付与 | ArgoCD が各 Namespace にアプリをデプロイするため |
| 3 | `app-of-apps` と `namespace-tekton-app` を適用 | dev / itst-1〜3 / prod 環境と `tekton-demo` Namespace ができる |
| 4 | パイプライン用の Secret を作成し `pipeline` SA に紐付け | GitHub（manifest への push）と Docker Hub（イメージの push） |
| 5 | `pipeline-app` を適用 | **demo-dev ができてから**適用する（demo-dev への RoleBinding を含むため） |
| 6 | `patch-console-app` を適用 | クラスタ内ビルドが終わるまで Pod は `ImagePullBackOff` になるが正常 |
| 7 | Webhook の設定値とデモ用 URL を表示 | 次の手順で使うので控えておく |

### 1-3. 構築結果の確認

```bash
oc get applications.argoproj.io -n openshift-gitops
```

次の 9 つがすべて `Synced` / `Healthy` になっていれば完了です。

`root-app`、`deploy-sampleapl-demo-dev`、`deploy-sampleapl-demo-itst-1`〜`3`、`deploy-sampleapl-demo-prod`、`tekton-namespace-app`、`pipeline-app`、`patch-console-app`

パッチ管理コンソールを開き、右上が「**クラスタ接続中**」になっていることも確認します。

---

## 2. GitHub Webhook の更新

クラスタのドメインは払い出しのたびに変わるため、**毎回** Webhook の Payload URL を更新します。URL はセットアップスクリプトの最後に表示されます（`oc get ingresses.config cluster -o jsonpath='{.spec.domain}'` でも確認できます）。

| リポジトリ | Payload URL | Content type | 用途 |
|---|---|---|---|
| sampleapl-demo-manifest | `https://openshift-gitops-server-openshift-gitops.<ドメイン>/api/webhook` | application/json | ArgoCD への即時反映 |
| sampleapl-demo | `http://el-sampleapl-listener-tekton-demo.<ドメイン>` | application/json | innerloop / outerloop パイプラインの起動 |

設定場所: 各リポジトリの Settings → Webhooks → 既存の Webhook を Edit → Payload URL を書き換えて Update webhook。

- manifest 側の Webhook がなくてもデモは動きます（パイプラインが ArgoCD に即時反映を指示するため）。
- sampleapl-demo 側は、パッチ適用デモだけなら不要です。innerloop / outerloop のデモも行う場合に設定してください。
- 更新後、Webhook 画面の Recent Deliveries で「Redeliver」を押し、緑のチェックになることを確認できます。

---

## 3. デモ準備

新しいクラスタではコンソールにスキャン結果がないため、最初に必ず実行します。

1. パッチ管理コンソール（`https://patch-console-patch-console.<ドメイン>`）を開く
2. 「**デモ準備を実行**」を押す
3. 完了まで待つ（約 10 分）。右側の「パイプライン」で進行を確認できる

完了すると、「① 現在の脆弱性」に古いベースイメージ（RHEL 9.2 ベース）の状態が表示されます。

| 表示 | 目安 |
|---|---|
| High | 500 件以上 |
| 修正可能 (C+H) | 300 件以上 |
| OS | redhat 9.2 |

デモ準備はチケットを起票しません。また、この時点のパイプラインは「古いベースに戻す」処理なので、脆弱性が増えるのが正常です。

**デモの前日までに一度通しで実行**しておくと安心です（初回はイメージのダウンロードなどで時間がかかることがあります）。

---

## 4. デモ実行

### 事前に開いておくタブ

1. パッチ管理コンソール（メイン画面）
2. ITSM モック（`https://itsm-mock-patch-console.<ドメイン>`）
3. OpenShift コンソール → Pipelines → PipelineRuns（Namespace: `tekton-demo`）
4. ArgoCD（`deploy-sampleapl-demo-dev`）
5. dev アプリ（`https://sampleapl-demo-demo-dev.<ドメイン>`）

### ① 現在の脆弱性を見せる（コンソール）

- 「① 現在の脆弱性」の件数タイルと、修正可能な CVE の一覧を見せる
- 伝えたいこと: フロンティア AI によって脆弱性の発見から悪用までの時間が短くなっている。放置されたベースイメージには、修正版があるのに適用されていない脆弱性がこれだけある

### ② パッチ適用を実行する

1. 「⑤で修正可能な脆弱性が残っていたら失敗させる」のチェックを確認する（下の[ゲートについて](#ゲート⑤について)を参照）
2. 「**パッチ適用**」を押す
3. ITSM モックのタブに切り替え、変更チケット（`CHG00300xx`）が「新規」→「実施中」になるのを見せる
4. コンソールのパイプライン表示、または OpenShift コンソールで ①〜⑥ の進行を見せる
   - ② 再ビルド: アプリのコードは変えず、ベースイメージだけを最新にしている
   - ③ リリース: マニフェストを書き換えて ArgoCD が dev に反映（GitOps）。ArgoCD のタブで同期を見せる
   - ④ 画面テスト: Playwright がブラウザで dev の画面を確認
   - ⑤ 再スキャン: 更新後のイメージをもう一度スキャン

### ③ 結果を見せる

- ITSM モックでチケットが「**クローズ**」になり、作業メモに Before → After の件数が記録されていること
- コンソールの「③ Before / After」で脆弱性が大きく減っていること（修正可能な件数は 300 件以上 → 数件程度）
- dev アプリの画面が変わらず動いていること
- 伝えたいこと: チケット起票からパッチ適用、テスト、クローズまでが自動でつながり、アプリのコード変更なしに短時間で脆弱性を解消できる

### ゲート（⑤）について

「⑤で修正可能な脆弱性が残っていたら失敗させる」にチェックすると、修正可能な Critical / High が 1 件でも残った場合にパイプラインを失敗扱いにします（チケットは「レビュー」になります）。

最新のベースイメージでも、Red Hat がまだ取り込んでいない修正が数件残ることがあります。

- デモの前に一度チェックありで試し、ゼロになるならチェックありで見せる
- 残る場合はチェックなしで実行し、「残りは Red Hat のベースイメージ更新待ちとして監視している」と説明する

setuptools 53.0.0 の 3 件は、Red Hat がバックポートで修正済みの誤検知のため、`sampleapl-demo/.trivyignore.yaml` で理由付きで除外しています（スキャンのログに除外理由が表示されます）。

### デモを繰り返すとき

「デモ準備を実行」を押せば、dev が古いベースイメージの状態に戻ります（約 10 分）。

---

## 5. トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| パイプラインの git push で `Invalid username or token` | `github-auth` Secret のトークンが誤っている（入力プロンプトへの貼り付けが途中で切れる等）。`bash scripts/setup-demo.sh` を再実行して正しいトークンを入力する（スクリプトは入力直後に GitHub / Docker Hub に問い合わせて有効性を確認する） |
| ArgoCD の `pipeline-app` が Progressing のまま | `tekton-workspace-pvc` は最初にパイプラインが使うまで割り当てられない（WaitForFirstConsumer）ため正常。innerloop などを一度実行すると Healthy になる |
| buildah で `unexpected EOF`（ベースイメージのダウンロード中） | レジストリとの一時的な通信断。コンソールからもう一度実行するか、OpenShift コンソールで PipelineRun を Rerun する |
| `wait-rollout` がタイムアウト | ArgoCD が同期していない。ArgoCD で `deploy-sampleapl-demo-dev` を Refresh / Sync する |
| `scan-after` が失敗 | ゲートが有効で修正可能な脆弱性が残っている。ログで対象を確認し、ゲートなしで実行する |
| コンソールが「クラスタ未接続」 | Pod の ServiceAccount が正しくない。`oc get deployment patch-console -n patch-console -o jsonpath='{.spec.template.spec.serviceAccountName}'` が `patch-console` であること |
| パッチ適用ボタンが押せない | 別のパイプラインが実行中。完了を待つ |
| チケットがクローズされない | notify タスクのログを確認（`oc logs -n tekton-demo -l tekton.dev/pipelineTask=notify --tail=50`） |
| デモ中に dev のイメージが勝手に変わった | sampleapl-demo の main に push すると innerloop が dev を上書きする。デモ中は push しない |
| コンソールのソースを直した | `oc start-build patch-demo-console -n patch-console --follow` のあと `oc rollout restart deployment/patch-console deployment/itsm-mock -n patch-console` |

---

## 6. デモ後

- パッチ管理コンソールと EventListener の Route には認証がありません。デモが終わったらクラスタを返却するか、Route を削除してください
- トークンをチャットやコマンドラインに貼った場合は、GitHub / Docker Hub で再発行してください
- Bastion のシェル履歴にトークンが残っていないか確認してください（`history | grep -i -E 'token|password|ghp_|dckr_'`）
