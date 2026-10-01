# The firewall between the repository and the game's files: a check that fails on anything that
# looks like one, run over the files git tracks by `make check-files` and CI, and over each new
# commit's by the pre-commit hook `make hooks` installs.

##@ Repository

.PHONY: check-files
check-files: ## Fail if a tracked file is one from the game, or looks like one
	scripts/check-files.sh

.PHONY: hooks
hooks: ## Use the repository's git hooks, which refuse commits holding the game's files
	git config core.hooksPath scripts/hooks
