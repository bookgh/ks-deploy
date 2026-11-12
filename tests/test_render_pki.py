"""Tests for safe CFSSL request rendering from the example cluster configuration."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from render_pki import EXPIRY, build_plan  # noqa: E402
from validate_config import parse_env_text  # noqa: E402


class PkiRendererTests(unittest.TestCase):
    def setUp(self) -> None:
        raw = (ROOT / "cluster.env.example").read_text(encoding="utf-8")
        self.values, errors = parse_env_text(raw, "cluster.env.example")
        self.assertEqual(errors, [])

    def test_renders_root_expiry_and_expected_certificate_identities(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "pki"
            plan = build_plan(self.values, root)
            self.assertEqual(plan["expiry"], EXPIRY)
            self.assertEqual(plan["certificate_authorities"], ["kubernetes", "etcd", "front-proxy"])
            identities = {item["name"]: item for item in plan["certificates"]}
            self.assertIn("192.0.2.10", identities["apiserver"]["hosts"])
            self.assertIn("127.0.0.1", identities["apiserver"]["hosts"])
            self.assertEqual(identities["kubelet-client-worker-01"]["cn"], "system:node:worker-01")
            self.assertEqual(identities["kubelet-client-worker-01"]["organization"], "system:nodes")
            self.assertEqual(identities["etcd-peer-master-01"]["profile"], "peer")
            request = json.loads((root / "ca/kubernetes/ca-csr.json").read_text(encoding="utf-8"))
            self.assertEqual(request["ca"]["expiry"], "876000h")

    def test_harbor_certificate_is_only_rendered_when_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            self.values["HARBOR_ENABLED"] = "true"
            plan = build_plan(self.values, Path(temp) / "pki")
            self.assertIn("harbor", plan["certificate_authorities"])
            harbor = next(item for item in plan["certificates"] if item["name"] == "harbor-server")
            self.assertEqual(harbor["hosts"], [self.values["HARBOR_DOMAIN"]])


if __name__ == "__main__":
    unittest.main()

