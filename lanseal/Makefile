.PHONY: check test
check:            ## static checks available without root or a network
	@for f in server/install.sh server/configure.sh server/uninstall.sh server/bin/lanseal server/lib/common.sh clients/linux/*.sh tests/leak-tests/*.sh; do bash -n $$f && echo "bash -n ok: $$f"; done
	@python3 -m py_compile server/lib/*.py && echo "python compile ok"
	@command -v shellcheck >/dev/null && shellcheck -x server/install.sh server/configure.sh server/bin/lanseal clients/linux/*.sh tests/leak-tests/*.sh || echo "shellcheck not installed (recommended)"
	@python3 server/lib/validate.py config/config.example.yaml
test: check
	@LANSEAL_REGISTRY=$$(mktemp -u) python3 server/lib/registry.py list >/dev/null && echo "registry smoke ok"
