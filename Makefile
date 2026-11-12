SHELL := /bin/bash
PYTHON ?= python3
CONFIG_ENV ?= cluster.env.example
CONFIG_VERSIONS ?= versions.yaml
CONFIG_CHARTS ?= charts.yaml

.PHONY: help install-dev validate test bash-n shellcheck shfmt lint check

help:
	@printf '%s\n' '目标：' '  install-dev  安装 Python 开发依赖' '  validate     校验配置模板/指定配置' '  test         运行单元测试' '  lint         运行 bash -n、ShellCheck、shfmt' '  check        运行 validate、test、lint'

install-dev:
	$(PYTHON) -m pip install -r requirements-dev.txt

validate:
	$(PYTHON) tools/validate_config.py --env $(CONFIG_ENV) --versions $(CONFIG_VERSIONS) --charts $(CONFIG_CHARTS)

test:
	$(PYTHON) -m unittest discover -s tests -v
	PYTHON=$(PYTHON) bash tests/test-config-cli.sh
	bash tests/test-common.sh

bash-n:
	@mapfile -d '' files < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './.venv/*' -print0); \
	if (($${#files[@]})); then bash -n "$${files[@]}"; else echo '未发现 Shell 脚本，跳过 bash -n'; fi

shellcheck:
	@mapfile -d '' files < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './.venv/*' -print0); \
	if (($${#files[@]})); then command -v shellcheck >/dev/null 2>&1 || { echo '缺少 shellcheck，请先安装 ShellCheck' >&2; exit 1; }; shellcheck -x "$${files[@]}"; else echo '未发现 Shell 脚本，跳过 ShellCheck'; fi

shfmt:
	@mapfile -d '' files < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './.venv/*' -print0); \
	if (($${#files[@]})); then command -v shfmt >/dev/null 2>&1 || { echo '缺少 shfmt，请先安装 shfmt' >&2; exit 1; }; shfmt -d -i 4 -ci "$${files[@]}"; else echo '未发现 Shell 脚本，跳过 shfmt'; fi

lint: bash-n shellcheck shfmt

check: validate test lint
