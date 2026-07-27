# Floci + API Gateway + Go Authorizer + .NET Lambda PoC

Floci上に、Terraformだけで次の最小構成を作るPoCです。

`API Gateway REST -> TOKEN Lambda Authorizer (Go) -> Hello Lambda (.NET 8)`

## 前提

- Docker / Docker Compose
- .NET SDK 8
- Go 1.22+
- Terraform 1.8+
- AWS CLI、`zip`、`curl`、`jq`

## 実行

```bash
make test
make deploy
make smoke
```

ローカルTerraformは入力変数や `*.tfvars` を使わず、`dev` workspaceの設定を
`infra/local/application/main.tf` の `workspace_config` から取得します。
`make deploy` は `dev` workspaceがなければ作成し、以降は自動的に選択します。

成功時のレスポンス例:

```json
{"message":"Hello","user":"Alice","userId":"user-001"}
```

終了は `make down` です。PoCのFloci状態はメモリ上に保持されるため、
コンテナを再作成するとTerraform管理リソースも再作成されます。

## ローカル認証

PoC専用トークンは次の形式です。トークンにはユーザーIDだけを含め、属性や権限は
Authorizerに同梱するJSONから取得します。

```text
Authorization: Bearer local:<user-id>
```

例: `local:user-001`

これはJWTではなく、ローカル結合試験用です。AWS環境ではGo AuthorizerがCognito access
tokenのRS256署名、issuer、client ID、token種別、発行時刻、有効期限を検証します。

## JSONによるAPI認可

[authorization.json](src/ApiAuthorizer/authorization.json)で次の3要素を管理します。

- `users`: 信頼するユーザー名と属性
- `userGroups`: 個別ユーザーまたは属性条件によるユーザーグループ
- `accessRightGroups`: 個別ユーザー、ユーザーグループ、属性条件をメンバーとして持つアクセス権グループ

アクセス権はアクセス権グループの`permissions`へHTTP actionとresourceパターンで設定します。

```json
{
  "accessRightGroups": {
    "hello-readers": {
      "members": {
        "users": ["user-003"],
        "userGroups": ["engineering-employees"],
        "identityProviderGroups": ["hello-readers"]
      },
      "permissions": [
        {
          "actions": ["GET"],
          "resources": ["/api/hello"]
        }
      ]
    }
  }
}
```

`identityProviderGroups`はCognito access tokenの`cognito:groups`と照合します。
これによりCognitoのユーザーグループをJSON側のアクセス権グループへ所属させつつ、
`users`ではCognitoの`sub`を指定して個別ユーザーを直接許可できます。

ユーザーグループとアクセス権グループの`match`は複合属性条件を指定できます。

```json
{
  "match": {
    "all": [
      {
        "attribute": "department",
        "operator": "equals",
        "values": ["engineering"]
      },
      {
        "attribute": "employmentType",
        "operator": "in",
        "values": ["employee", "partner"]
      }
    ],
    "any": [
      {
        "attribute": "location",
        "operator": "equals",
        "values": ["tokyo"]
      },
      {
        "attribute": "project",
        "operator": "contains",
        "values": ["hello"]
      }
    ]
  }
}
```

`all`は全条件一致、`any`は一つ以上の一致が必要です。両方を指定した場合は
`all`の全条件と`any`の最低一条件を満たす必要があります。operatorは
`equals`、`notEquals`、`in`、`contains`、`exists`、`notExists`を利用できます。
一致するAllow権限がなければデフォルトでDenyします。
Go Authorizerは外部ライブラリに依存せず、標準ライブラリだけでLambda Runtime APIを
実装しています。`authorization.json`はLambda成果物へ同梱され、起動時に検証・読込されます。
JSON変更を反映するにはAuthorizerを再ビルド・再デプロイします。

## 非同期検索 + S3一時ダウンロード

API Gatewayのバリエーションとして、同期APIではタイムアウトしやすい検索・帳票出力を
バックグラウンド処理するサンプルを実装しています。

```text
Angular
  | POST /api/search-jobs                    Authorization: Bearer <token>
  v
API Gateway -> Go Authorizer -> Search API Lambda (.NET)
                                      | DynamoDBへQUEUEDを保存
                                      v
                                     SQS
                                      v
                              Search Worker Lambda (.NET)
                                      | 20,000件を検索してCSVを出力
                                      +----> private S3 bucket
                                      |
                                      +----> DynamoDBをCOMPLETEDへ更新

Angular
  | GET /api/search-jobs/{jobId} をポーリング
  v
Search API Lambda -> 完了時だけ5分間有効なS3署名URLを返す
```

開始APIはすぐに`202 Accepted`を返します。

```http
POST /api/search-jobs
Authorization: Bearer <token>
Content-Type: application/json

{"query":"engineering","maxResults":250}
```

```json
{
  "jobId": "8c581a6915a648bbba315e82c2d4c97c",
  "status": "QUEUED",
  "statusUrl": "/api/search-jobs/8c581a6915a648bbba315e82c2d4c97c"
}
```

フロントエンドへの完了通知は、最初の実装ではFlociと実AWSの両方で扱いやすい
**短間隔ポーリング**にしています。Angularは`QUEUED` / `RUNNING`の間だけGETし、
`COMPLETED`または`FAILED`で停止します。WebSocketの接続・再接続や接続ID管理を
持たないため、この規模のPoCでは動作差分を小さくできます。

一時データには次の防御を入れています。

- S3 bucketは非公開で、公開ACL/公開bucket policyをブロック
- Search APIとWorkerはIAM Roleを分離し、S3/SQS/DynamoDBを用途別の最小権限に限定
- ダウンロードURLは要求の都度生成し、有効期間は最大5分
- URLを取得できるのはジョブを作成したユーザーだけ。他ユーザーには`404`を返す
- ジョブ作成から1日後はAPIが`410 Gone`を返し、新しいURLを発行しない
- S3の`results/`は1日でExpiration、不完全なmultipart uploadも1日で中止
- DynamoDBのジョブメタデータも`expiresAt` TTLで削除
- Worker失敗時は最大3回処理し、その後はDLQへ退避

S3 LifecycleとDynamoDB TTLは非同期削除であり、指定時刻ぴったりの物理削除を保証する
機能ではありません。そのため、利用期限はAPIでも即時判定し、物理データの後片付けを
Lifecycle/TTLへ任せています。署名URLは秘密情報と同じ扱いにし、ログや永続ストレージへ
保存しないでください。AngularもURLを画面表示中だけ保持します。

CSVリンクはS3を別オリジンとして新しいタブで直接開くため、Angularがレスポンス本文を
読むためのS3 CORSは不要です。将来`HttpClient`でCSVを読み込む場合は、S3 bucket側にも
CloudFront originを完全一致で許可するCORS設定が必要です。

Floci 1.5.33では、TerraformによるS3 Lifecycle、DynamoDB TTL、SQS/DLQ、
SQS Lambda event source mapping、S3署名URLを実際に構築し、
`make smoke`で次を確認済みです。

- Authorizerで許可されたユーザーによるジョブ作成
- SQSからWorker Lambdaを起動し、20,000件を走査
- DynamoDBの`QUEUED`から`COMPLETED`への状態更新
- private S3へのCSV保存と5分署名URLによる実ダウンロード
- 別ユーザーによるジョブ参照の拒否、権限なしユーザーによるジョブ作成の拒否
- S3の1日Expiration設定とDynamoDB TTL設定

24時間待つ物理削除テストは通常のsmokeには含めず、設定APIとアプリ側の期限判定までを
ローカルで確認します。Flociのコンテナを再作成するとメモリ上のデータはすべて消えます。

参考:

- [Floci](https://github.com/floci-io/floci)
- [Floci compatibility tests](https://github.com/floci-io/floci-compatibility-tests)
- [Amazon S3 presigned URL](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html)
- [Amazon S3 Lifecycle Expiration](https://docs.aws.amazon.com/AmazonS3/latest/API/API_LifecycleExpiration.html)

### 次に追加しやすいAPIパターン

優先度順では次のサンプルが有用です。

1. **署名付きupload + S3 Event**: 大きな入力ファイルをAPI Gateway/Lambda経由にせず
   S3へ直接uploadし、S3 Eventから検証・変換Lambdaを起動するパターン
2. **Step Functionsによる複数段処理**: 検索、集計、CSV生成、通知を分け、再試行箇所と
   実行履歴を明確にする長時間ワークフロー
3. **WebSocket完了通知**: ポーリングの代わりにAPI Gateway WebSocketで完了イベントを
   pushするパターン。実AWS向けの価値は高い一方、Floci互換性は個別PoCが必要
4. **Webhook / EventBridge通知**: ブラウザではなく外部システムへ完了を通知し、
   署名検証、冪等性、再送を確認するパターン
5. **Athena非同期クエリ**: 大きなS3データをLambdaメモリへ読み込まず検索し、
   QueryExecutionIdを現在のジョブAPIと同じ形で追跡するパターン

次の一手としては、現在のdownloadフローと対になる「署名付きupload + S3 Event」が
再利用性とFlociでの検証価値のバランスが最も良いです。

## CloudFrontとAPI Gatewayが別ドメインになる点

同一ドメインを前提にしていません。AngularはAPI GatewayのURLを環境設定として保持し、
API Lambdaの `CORS_ALLOW_ORIGIN` にはCloudFrontのオリジンを設定します。
Terraformは `Authorization` ヘッダーを許可するOPTIONSプリフライトも構築します。

- local `dev` workspace: `frontend_origin = "http://localhost:4200"`
- AWS: `frontend_origin = "https://<distribution>.cloudfront.net"`

本番では `*` を使用せず、CloudFront URLを完全一致で指定してください。Bearer tokenを
JavaScriptから送るため、Cookieのsame-site共有は前提にしません。将来Cookie認証を使う場合は
API側のCORS credentials、Cookieの `SameSite=None; Secure`、CSRF対策が別途必要です。

### 本番での認証情報の受け渡し

CloudFront用の認証CookieをAPI Gatewayへ転送する構成にはしません。Cookieは設定された
ドメインへだけ送信されるため、`*.cloudfront.net` のCookieは
`*.execute-api.ap-northeast-1.amazonaws.com` へ自動送信されません。

実装ではLambda@EdgeをOAuth 2.0/OIDCクライアントとして扱い、Cognito User Poolの
Authorization Code Grant + PKCEを利用します。

```text
Browser
  |
  | 1. CloudFrontへアクセス
  v
CloudFront / Lambda@Edge等
  |
  | CloudFront用Cookieを検証し、静的ファイルへのアクセスを制御
  v
Angular
  |
  | 2. Cognito /oauth2/authorizeへPKCE付きでリダイレクト
  | 3. CloudFront /auth/callbackへAuthorization Codeを返却
  v
Cognito
  |
  | 4. Lambda@EdgeがCode + code_verifierをtokenへ交換
  | 5. ID/access tokenを検証してHttpOnly Cookieへ保存
  v
Angular
  |
  | 6. 同一originの /auth/token から短命access tokenを取得
  | 7. Authorization: Bearer <access token>
  v
API Gateway（CloudFrontとは別ドメイン）
  |
  | 8. Go Lambda AuthorizerがJWTとresource/actionを検証
  v
.NET Application Lambda
```

APIにはID tokenではなくaccess tokenを送ります。Angularは次のヘッダーを設定します。

```http
Authorization: Bearer <Cognito access token>
```

アクセストークンはAngularのメモリ上だけで保持し、`localStorage`や`sessionStorage`には
保存しません。AngularはHttpOnly Cookieを直接読み取らず、Lambda@Edgeがセッションを
再検証する同一originの`/auth/token`を通して取得します。CookieはAPI Gatewayへ送らず、
API Gateway側もCookieを信頼しません。
CloudFrontとAPIは同じCognitoユーザーセッションを利用できますが、それぞれ独立して
「フロントエンドへ入れるか」と「APIを実行できるか」を判定します。

現在のaccess/ID token有効期間は1時間です。refresh tokenをブラウザへ公開しない構成のため、
期限切れ後はCognitoへ再ログインします。

Lambda Authorizerでは少なくとも以下を検証します。

- JWT署名とCognitoのJWKS
- `iss`
- `client_id` / `aud`
- `exp` / `iat`
- `token_use == "access"`
- OAuth scope、Cognito group、role、permission
- APIのHTTP method、resource、action

Angularから`Authorization`ヘッダーを送るとブラウザがOPTIONSプリフライトを実行するため、
API GatewayはCloudFrontオリジンを完全一致で許可します。Bearer方式では
`Access-Control-Allow-Credentials`は使用しません。

参考:

- [Amazon Cognito: Authorization Code Grant with PKCE](https://docs.aws.amazon.com/cognito/latest/developerguide/using-pkce-in-authorization-code.html)
- [Amazon Cognito: API GatewayとLambda Authorizer](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-accessing-resources-api-gateway-and-lambda.html)

## Angularサンプル画面

Angular 22のサンプル画面から、Floci上のAPI Gateway、Go Authorizer、.NET Lambdaまでを
ブラウザで確認できます。Node.js 26以上を使用します。

```bash
# 初回またはpackage-lock.json更新後
make frontend-install

# FlociとAPIを起動・デプロイ
make up
make deploy

# http://localhost:4200 でAngularを起動
make frontend
```

`make frontend`はTerraformの`floci_invoke_url` outputから現在のAPI Gateway URLを取得し、
`frontend/public/config.json`を更新してから開発サーバーを起動します。そのためFlociを
再作成してAPI IDが変わっても、Angular側のソースを編集する必要はありません。

画面では次のローカル用Bearer tokenを切り替えて認可結果を確認できます。

- Alice (`user-001`): ユーザーグループ経由でAllow
- Carol (`user-003`): 個別ユーザー権限でAllow
- Bob (`user-002`): 権限がないためDeny

本番のCognito access tokenとは異なり、`Bearer local:<user-id>`はPoC専用です。
ブラウザは`localhost:4200`から`localhost:4566`へ別オリジンでアクセスし、
実装済みのCORSプリフライトと`Authorization`ヘッダー送信も確認します。

### AWSへの画面デプロイ

AWSでは`infra/aws/foundation`が非公開S3、CloudFront Origin Access Control、
CloudFront distributionを管理します。CloudFront URLはSSM Parameter Storeを経由して
Application StackのCORSへ渡されるため、CloudFrontとAPI Gatewayが別ドメインでも
AngularからBearer tokenを送信できます。

新規環境ではCloudFront URL確定のためfoundationを2回、続いてapplicationをapplyします。
その後、次を実行します。

```bash
make frontend-deploy-aws
```

このコマンドはAngularをbuildし、Terraform outputからAPI URL、S3 bucket、
CloudFront distributionを取得して、runtime `config.json`生成、S3同期、
CloudFront invalidationまで実施します。

CloudFront viewer-requestへLambda@Edgeログインゲートを関連付けています。
未認証アクセスはCognito managed loginへリダイレクトされ、Authorization Code + PKCEの
callback後にだけAngularを配信します。

```text
Browser -> CloudFront -> Lambda@Edge
                            |
                            +-- sessionなし -> Cognito /oauth2/authorize
                            |
                            +-- /auth/callback
                            |      +-- state / nonce / PKCE検証
                            |      +-- codeをtokenへ交換
                            |      +-- ID/access token署名・claims検証
                            |      +-- HttpOnly session/access Cookie設定
                            |
                            +-- /auth/token -> access tokenをAngularへ一時引渡し
                            |
                            +-- sessionあり -> S3 / Angular
```

Cookieは`Secure; HttpOnly; SameSite=Lax`で、Angularから直接読み取りません。
Lambda@EdgeはCognito JWKSによるRS256署名と`iss`、`aud`/`client_id`、`token_use`、
`exp`をリクエストごとに検証します。`/auth/logout`は両Cookieを削除してCognito logoutへ
遷移します。

API Authorizerはaccess tokenの`cognito:groups`を
`authorization.json`の`identityProviderGroups`へ照合します。foundationが作成する
`hello-readers`グループへテストユーザーを追加する例:

```bash
aws cognito-idp admin-add-user-to-group \
  --region ap-northeast-1 \
  --user-pool-id "$(terraform -chdir=infra/aws/foundation output -raw cognito_user_pool_id)" \
  --username demo@example.com \
  --group-name hello-readers
```

Lambda@EdgeはAWS仕様により`us-east-1`へ番号付きversionとして作成し、
設定値は環境変数ではなくTerraform生成の`config.json`へ同梱します。

テストユーザーはTerraformで管理せず、必要に応じてCognito CLIまたは管理画面から作成します。
パスワードやユーザー情報をTerraform stateおよびGitへ保存しないためです。

## ディレクトリ

- `src/ApiAuthorizer`: Goによる認証とJSONベースのAPI resource/action認可
- `src/HelloApi`: API Gateway proxy Lambda
- `src/SearchJobs`: 非同期検索API、SQS Worker、S3署名URL発行を行う.NET Lambda
- `frontend`: Angular 22による認証・認可確認用サンプル画面
- `infra/modules/application`: local/AWS共有Terraform Module
- `infra/local/application`: AWSに接続しないFloci用rootとlocal state
- `infra/aws/application`: 実AWS用rootとS3 backend定義
- `infra/local/foundation`: 将来のFloci固有基盤
- `infra/aws/foundation`: S3、CloudFront、Cognito、Lambda@Edgeログインゲート
- `src/FrontendAuthGate`: CloudFrontログインゲートとNode.js単体テスト
- `scripts`: package、deploy、smoke test

Applicationのリソース定義は共通Moduleに置き、Providerとbackendだけを薄いrootで
分離しています。ローカルのbuild、validate、apply、smoke testはAWS credentialsや
AWS上のstate backendを必要としません。実AWS側は次のコマンドでAWSへ接続せずに
構文とProvider schemaを検証できます。

```bash
terraform -chdir=infra/aws/application init -backend=false
terraform -chdir=infra/aws/application validate
```

実デプロイ時だけS3 backend設定とAWS credentialsを指定し、backend初期化後に
`dev` workspaceを作成・選択します。`default` workspaceからのplan/applyは
workspace guardが拒否します。

Flociの呼出しURLはLocalStack互換形式
`/restapis/{api-id}/{stage}/_user_request_/api/hello` を利用します。

## 現PoCの境界

CloudFront/S3/Cognito/Lambda@Edgeログインゲートは実AWSへ実装済みです。
Lambda@Edgeのグローバル複製、Cognito managed login、Cookie統合は実AWSで確認し、
認証ロジック本体はNode.js単体テストで検証します。これらはFlociの再現対象外です。

非同期検索はFloci上でAPI Gateway、Authorizer、Lambda、DynamoDB、SQS event source、
S3保存、署名URLダウンロードまで確認済みです。S3 Lifecycleの設定APIも互換ですが、
実時間経過後の削除タイミング、SQS/Lambdaの大規模並列実行、DLQの運用アラームは
最終的に実AWSで確認します。

Floci 1.5.33はAPI Gateway integrationの `timeout_milliseconds` を読取時に `0` と返すため、
2回目以降の `terraform plan` では `0 -> 50` の既知差分が表示されます。これはFlociの
control-plane互換差分で、API実行には影響しません。ローカルのCORSプリフライトはFlociの
グローバルCORS機能が先に処理し、同じModuleのOPTIONS設定は実AWSで使用されます。
またFloci 1.5.33は`PutGatewayResponse`を未実装のため、共有Moduleの
`enable_gateway_responses`をlocal rootだけ`false`にしています。AWSでは`true`とし、
Authorizerが返す401/403にもCloudFront origin向けCORSヘッダーを設定します。
