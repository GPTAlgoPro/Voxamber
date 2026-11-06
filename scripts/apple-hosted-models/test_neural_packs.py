import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import prepare_neural_packs as builder


class NeuralPackGuards(unittest.TestCase):
    def test_pinned_three_pack_scope_and_total_parameter_budget(self):
        catalog = builder.load_catalog()
        self.assertEqual({p["group"] for p in catalog["packs"]}, {"intent", "image", "shape"})
        self.assertEqual(catalog["deployedParameterCountConservative"], 7_911_616_876)
        self.assertFalse(catalog["publicationEnabled"])
        self.assertNotIn("Voxamber-Qwen35-4B-INT4", {p["assetPackID"] for p in catalog["packs"]})

    def test_unknown_duplicate_and_nonfinite_json_fails_closed(self):
        for text in ['{"id":1,"id":2}', '{"outer":{"a":1,"a":2}}', '{"value":NaN}']:
            with self.assertRaises(ValueError):
                builder.strict_json(text)

    def test_archive_paths_cannot_escape_or_select_scripts(self):
        for path in ["/weights", "../weights", "a/../weights", "a//weights", "a\\weights", "a%2fweights", "x.py", "a/x.js", "x.sh"]:
            with self.assertRaises(ValueError, msg=path):
                builder.relative_path(path)
        self.assertEqual(builder.relative_path("TextEncoder.mlmodelc/weights/weight.bin"),
                         "TextEncoder.mlmodelc/weights/weight.bin")
        self.assertEqual(builder.relative_path("chat_template.jinja"), "chat_template.jinja")

    def test_payload_hash_permissions_and_ancestor_symlink_are_checked(self):
        # TemporaryDirectory can resolve through /var -> /private/var on macOS.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            path = root / "file.bin"; path.write_bytes(b"pinned")
            pin = {"relativePath": "file.bin", "byteCount": 6, "sha256": hashlib.sha256(b"pinned").hexdigest()}
            builder.verify_file(path, pin)
            path.chmod(0o755)
            with self.assertRaises(ValueError):
                builder.verify_file(path, pin)
            path.chmod(0o644); path.write_bytes(b"edited")
            with self.assertRaises(ValueError):
                builder.verify_file(path, pin)
            real = root / "real"; real.mkdir(); (real / "file.bin").write_bytes(b"pinned")
            link = root / "linked"; link.symlink_to(real, target_is_directory=True)
            with self.assertRaises(ValueError):
                builder.verify_file(link / "file.bin", pin)

    def test_native_contract_identity_ignores_publication_metadata_but_not_actual_pins(self):
        manifest = json.loads((builder.ROOT / "Apple/ThreeLiveStudio/Resources/NeuralModels/ShapeHunyuan21.json").read_text())
        expected = builder.model_pin_identity(manifest)
        changed = json.loads(json.dumps(manifest)); changed["apple"]["available"] = True
        changed["identityStatus"] = "different-evidence-state"
        changed["packaging"] = {"notPartOfRuntimePinProjection": True}
        self.assertEqual(builder.model_pin_identity(changed), expected)
        changed["files"][0]["sha256"] = "0" * 64
        self.assertNotEqual(builder.model_pin_identity(changed), expected)

    def test_boolean_sizes_cannot_be_treated_as_one_byte_model_files(self):
        with self.assertRaises(ValueError):
            builder.validate_pin({"relativePath": "config.json", "byteCount": True, "sha256": "a" * 64})


if __name__ == "__main__":
    unittest.main()
