.PHONY: build test frontend-install frontend frontend-build frontend-deploy-aws up deploy smoke down validate

build:
	./scripts/build-lambdas.sh

test:
	dotnet test --disable-build-servers -m:1
	cd src/ApiAuthorizer && GOCACHE=$(CURDIR)/.cache/go-build GOMODCACHE=$(CURDIR)/.cache/go-mod go test ./...
	node --test src/FrontendAuthGate/index.test.mjs
	cd frontend && npm test

frontend-install:
	cd frontend && npm ci

frontend:
	./scripts/start-frontend.sh

frontend-build:
	cd frontend && npm run build

frontend-deploy-aws:
	./scripts/deploy-frontend-aws.sh

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
