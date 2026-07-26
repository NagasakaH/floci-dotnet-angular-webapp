# Floci + API Gateway + Go Authorizer + .NET Lambda PoC

Floci上に、Terraformだけで次の最小構成を作るPoCです。

`API Gateway REST -> TOKEN Lambda Authorizer (Go) -> Hello Lambda (.NET 8)`

## 前提

- Docker / Docker Compose
- .NET SDK 8
- Go 1.22+
- Terraform 1.8+
- `zip` と `curl`

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

これはJWTではなく、ローカル結合試験用です。AWS環境ではCognito/OIDCの署名・issuer・
audience・期限を検証する実装へ交換します。認証後のユーザーIDをJSON認可エンジンへ渡す
境界は維持します。

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
        "userGroups": ["engineering-employees"]
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

本番ではAngularをOAuth 2.0/OIDCのpublic clientとして扱い、Cognito User Poolの
Authorization Code Grant + PKCEを利用する想定です。

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
  | 3. CloudFront URLへAuthorization Codeを返却
  | 4. AngularがCode + code_verifierをToken Endpointで交換
  v
Cognito
  |
  | access token / ID token / refresh token
  v
Angular
  |
  | 5. Authorization: Bearer <access token>
  v
API Gateway（CloudFrontとは別ドメイン）
  |
  | 6. Lambda AuthorizerがJWTとresource/actionを検証
  v
.NET Application Lambda
```

APIには原則としてID tokenではなくaccess tokenを送ります。AngularはAPI呼出し用の
HTTP interceptorで次のヘッダーを設定します。

```http
Authorization: Bearer <Cognito access token>
```

アクセストークンは可能な限りブラウザのメモリ上で保持し、`localStorage`への長期保存は
避けます。トークン更新、ログアウト、失効処理はCognito対応OIDCライブラリへ委譲します。
CloudFront用CookieをHttpOnlyにした場合も、AngularがそのCookieを読み出す必要はありません。
CloudFrontとAPIは同じCognitoユーザーセッションを利用できますが、それぞれ独立して
「フロントエンドへ入れるか」と「APIを実行できるか」を判定します。

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

## ディレクトリ

- `src/ApiAuthorizer`: Goによる認証とJSONベースのAPI resource/action認可
- `src/HelloApi`: API Gateway proxy Lambda
- `infra/modules/application`: local/AWS共有Terraform Module
- `infra/local/application`: AWSに接続しないFloci用rootとlocal state
- `infra/aws/application`: 実AWS用rootとS3 backend定義
- `infra/local/foundation`: 将来のFloci固有基盤
- `infra/aws/foundation`: 将来のCloudFront/S3/Cognito等のAWS基盤
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

Angular、S3、CloudFront、Cognito、CloudFront側の認証ゲートは次フェーズです。
CloudFront認証はLambda@Edge/CloudFront Functionsの実AWS固有挙動を含むため、
Flociで再現できるロジックと実AWSで確認する統合部分を分けます。

Floci 1.5.33はAPI Gateway integrationの `timeout_milliseconds` を読取時に `0` と返すため、
2回目以降の `terraform plan` では `0 -> 50` の既知差分が表示されます。これはFlociの
control-plane互換差分で、API実行には影響しません。ローカルのCORSプリフライトはFlociの
グローバルCORS機能が先に処理し、同じModuleのOPTIONS設定は実AWSで使用されます。
