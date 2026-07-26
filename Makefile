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
	terraform -chdir=infra/environments/local init -backend=false
	terraform -chdir=infra/environments/local validate
	terraform -chdir=infra/environments/aws init -backend=false
	terraform -chdir=infra/environments/aws validate
