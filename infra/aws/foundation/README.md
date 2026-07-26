# AWS foundation

更新頻度の低いS3、CloudFront、Cognito、ACM等を管理するためのrootです。
Application Stackとは別のremote stateで管理します。

CloudFront URLが確定した後、`../application/main.tf` のdev設定または
SSM Parameter Store経由でApplication Stackへ渡します。
