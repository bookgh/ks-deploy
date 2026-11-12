"""Unit tests for the M0 configuration validator."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from validate_config import parse_env_text, validate_files  # noqa: E402


class ConfigValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.work = Path(self.temp_dir.name)
        self.env = (ROOT / "cluster.env.example").read_text(encoding="utf-8")
        self.versions = (ROOT / "versions.yaml").read_text(encoding="utf-8")
        self.charts = (ROOT / "charts.yaml").read_text(encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def validate(self, env: str | None = None, versions: str | None = None, charts: str | None = None) -> list[str]:
        env_path = self.work / "cluster.env"
        versions_path = self.work / "versions.yaml"
        charts_path = self.work / "charts.yaml"
        env_path.write_text(self.env if env is None else env, encoding="utf-8")
        versions_path.write_text(self.versions if versions is None else versions, encoding="utf-8")
        charts_path.write_text(self.charts if charts is None else charts, encoding="utf-8")
        return validate_files(env_path, versions_path, charts_path)

    def test_example_configuration_is_valid(self) -> None:
        self.assertEqual(self.validate(), [])

    def test_duplicate_node_ip_is_rejected(self) -> None:
        bad_env = self.env.replace("worker-01=192.0.2.21", "worker-01=192.0.2.10")
        errors = self.validate(env=bad_env)
        self.assertTrue(any("节点 IP 重复" in error for error in errors), errors)

    def test_invalid_cidr_is_rejected(self) -> None:
        bad_env = self.env.replace("POD_CIDR=10.244.0.0/16", "POD_CIDR=10.244.1.1/16")
        errors = self.validate(env=bad_env)
        self.assertTrue(any("POD_CIDR" in error and "CIDR" in error for error in errors), errors)

    def test_overlapping_pod_and_service_cidr_is_rejected(self) -> None:
        bad_env = self.env.replace("SERVICE_CIDR=10.96.0.0/12", "SERVICE_CIDR=10.244.0.0/16")
        errors = self.validate(env=bad_env)
        self.assertTrue(any("不允许重叠" in error for error in errors), errors)

    def test_empty_kubernetes_version_is_rejected(self) -> None:
        bad_versions = self.versions.replace("version: v1.37.2", 'version: ""')
        errors = self.validate(versions=bad_versions)
        self.assertTrue(any("kubernetes.version" in error for error in errors), errors)

    def test_invalid_semver_identifiers_are_rejected(self) -> None:
        invalid_versions = ("v1.37.2-", "v1.37.2-01", "v01.37.2", "v1.37.2+build.")
        for invalid_version in invalid_versions:
            with self.subTest(version=invalid_version):
                bad_versions = self.versions.replace("v1.37.2", invalid_version)
                errors = self.validate(versions=bad_versions)
                self.assertTrue(any("kubernetes.version" in error for error in errors), errors)

    def test_empty_yaml_document_is_rejected(self) -> None:
        errors = self.validate(versions="\n")
        self.assertTrue(any("根节点必须是 YAML mapping" in error for error in errors), errors)

    def test_unknown_environment_key_is_rejected(self) -> None:
        errors = self.validate(env=self.env + "UNRECOGNIZED_OPTION=true\n")
        self.assertTrue(any("未知配置项" in error for error in errors), errors)

    def test_missing_environment_key_is_rejected(self) -> None:
        bad_env = "\n".join(line for line in self.env.splitlines() if not line.startswith("SSH_PORT=")) + "\n"
        errors = self.validate(env=bad_env)
        self.assertTrue(any("SSH_PORT" in error and "缺少必填" in error for error in errors), errors)

    def test_invalid_offline_combination_is_rejected(self) -> None:
        bad_env = self.env.replace("OFFLINE_MODE=false", "OFFLINE_MODE=true")
        errors = self.validate(env=bad_env)
        self.assertTrue(any("IMAGE_MODE=online" in error for error in errors), errors)

    def test_unknown_proxy_mode_is_rejected(self) -> None:
        bad_env = self.env.replace("PROXY_MODE=nftables", "PROXY_MODE=unknown")
        errors = self.validate(env=bad_env)
        self.assertTrue(any("PROXY_MODE" in error and "只允许" in error for error in errors), errors)

    def test_locked_chart_without_version_is_rejected(self) -> None:
        bad_charts = self.charts.replace("version_lock_status: pending", "version_lock_status: locked", 1)
        errors = self.validate(charts=bad_charts)
        self.assertTrue(any("charts.calico.version" in error for error in errors), errors)

    def test_pending_chart_with_blank_version_is_rejected(self) -> None:
        bad_charts = self.charts.replace("version_lock_status: pending", 'version_lock_status: pending\n    version: ""', 1)
        errors = self.validate(charts=bad_charts)
        self.assertTrue(any("pending 时不得设置 version" in error for error in errors), errors)

    def test_duplicate_yaml_key_is_rejected(self) -> None:
        bad_versions = self.versions.replace("schema_version: 1", "schema_version: 1\nschema_version: 1")
        errors = self.validate(versions=bad_versions)
        self.assertTrue(any("duplicate key" in error for error in errors), errors)

    def test_shell_metacharacters_are_rejected_without_execution(self) -> None:
        _, errors = parse_env_text(self.env.replace("SSH_USER=root", "SSH_USER=root;touch /tmp/should-not-exist"), "test.env")
        self.assertTrue(any("不允许的字符" in error for error in errors), errors)

    def test_gitignore_excludes_runtime_secrets(self) -> None:
        ignore_content = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for pattern in ("/cluster.env", "/pki/", "/artifacts/", "/output/", "/state/", "*.kubeconfig", "*.key", "*-key.pem", "*.pem", "*.p12", "*.pfx", "*.token"):
            with self.subTest(pattern=pattern):
                self.assertIn(pattern, ignore_content)


if __name__ == "__main__":
    unittest.main()
