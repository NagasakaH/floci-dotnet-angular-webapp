.PHONY: build test up deploy smoke down validate

build:
	./scripts/build-lambdas.sh

test:
	dotnet test --disable-build-servers -m:1

up:
	docker compose up -d --wait

deploy:
	./scripts/deploy-local.sh

smoke:
	./scripts/smoke-test.sh

down:
	docker compose down

validate: build
	terraform -chdir=infra/local/application init -backend=false
	terraform -chdir=infra/local/application workspace select dev || terraform -chdir=infra/local/application workspace new dev
	terraform -chdir=infra/local/application validate
	terraform -chdir=infra/aws/application init -backend=false
	terraform -chdir=infra/aws/application validate
