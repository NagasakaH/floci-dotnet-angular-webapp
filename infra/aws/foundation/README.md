# AWS foundation

更新頻度の低いS3、CloudFront、Cognito、ACM等を管理するrootです。
Application Stackとは別のS3 remote stateと`dev` workspaceで管理します。

Angular配信用の非公開S3 bucket、CloudFront Origin Access Control、
CloudFront distribution、Cognito User Pool、Lambda@Edgeログインゲートを構築します。
CloudFront URLは
`/floci-poc/dev/frontend-origin`としてSSM Parameter Storeへ保存され、
Application StackがAPI CORSの許可originとして読み取ります。
Cognito issuerとapp client IDもSSM Parameter Storeへ保存し、Application Stackの
Go Authorizerへ信頼設定として渡します。

```bash
terraform init -reconfigure \
  -backend-config=bucket=terraform-nagasakah \
  -backend-config=key=floci-dotnet-angular-webapp/foundation/terraform.tfstate \
  -backend-config=region=ap-northeast-1 \
  -backend-config=use_lockfile=true
terraform workspace select dev
terraform apply
terraform apply
```

Angularのbuild成果物はroot directoryから次のコマンドで配置します。

```bash
make frontend-deploy-aws
```

未認証アクセスはLambda@EdgeからCognito managed loginへリダイレクトされます。
Authorization Code + PKCE完了後、署名検証済みID/access tokenをHttpOnly Cookieへ保存して
CloudFront配信を許可します。Angularは認証済みの`/auth/token`からaccess tokenをメモリへ
取得し、別ドメインのAPI GatewayへBearer tokenとして送信します。ログアウトURLは
`/auth/logout`です。

`hello-readers` Cognito groupもこのStackで管理します。ユーザー自体はパスワードをstateへ
保存しないためTerraform管理外とし、必要なユーザーをこのgroupへ運用で所属させます。

Lambda@Edgeの制約により関数は`us-east-1`へ番号付きversionとして作成されます。
新規AWSアカウントの初回だけは2回applyします。1回目は一時的なcallback設定でCloudFrontと
SSM Parameterを作成し、2回目が確定したCloudFront URLでCognito clientとLambda@Edgeを
更新します。既存環境では通常1回で差分が収束します。

ユーザーとパスワードはTerraform stateへ保存せず、Cognito CLIまたは管理画面で管理します。
