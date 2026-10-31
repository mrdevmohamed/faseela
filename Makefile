# faseela — entry point for the everyday tasks. `make` lists them.
SHELL := /bin/bash
SCRIPTS := $(wildcard bootstrap/*.sh bootstrap/seed/*.sh scripts/*.sh tests/*.sh)
TARGET  ?= /mnt/faseela
ISOLATION ?= env

.DEFAULT_GOAL := help
.PHONY: help recipes lint test check dry-run build resume stages clean

help: ## show this list
	@awk 'BEGIN{FS=":.*## "} /^[a-z-]+:.*## /{printf "  \033[1mmake %-9s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo; echo "  variables: TARGET=$(TARGET)  ISOLATION=$(ISOLATION)"

recipes: ## fetch the recipes from faseela-repo (RECIPES_REF=<ref> for a specific one)
	bash bootstrap/fetch-recipes.sh

lint: ## bash -n + ShellCheck (errors) on every shell script, actionlint if installed
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done; echo "syntax ok ($(words $(SCRIPTS)) scripts)"
	@if command -v shellcheck >/dev/null; then shellcheck --severity=error $(SCRIPTS) && echo "shellcheck ok"; else echo "shellcheck not installed - skipped"; fi
	@if command -v actionlint >/dev/null; then actionlint -ignore 'SC2012' .github/workflows/*.yml && echo "actionlint ok"; else echo "actionlint not installed - skipped"; fi

test: ## run every test script, ending with one summary table
	bash tests/run-all.sh

check: lint test ## lint + test (what CI runs, minus the recipes)

dry-run: ## plan the whole build at every isolation level, build nothing
	@for l in none env sandbox closure; do echo "== $$l"; bash bootstrap/build-all.sh --dry-run --isolation $$l /tmp/faseela-dry-$$l >/dev/null || exit 1; done; echo "dry runs ok"

build: ## build the whole distribution into TARGET (root; hours)
	sudo ./bootstrap/build-all.sh --isolation $(ISOLATION) $(TARGET)

resume: build ## same command: finished stages are skipped, the broken one continues

stages: ## which stages of TARGET are done / failed
	./bootstrap/build-all.sh --list-stages $(TARGET)

clean: ## remove local scratch (build/, out/, fetched recipes and nawa source)
	rm -rf build out nawa srccache recipes .recipes-rev .recipes-new.* .recipes-fetch.* .nawa-fetch.*
