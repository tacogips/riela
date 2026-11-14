"""No network or provider calls; exact old/new source-shape adaptation fixtures."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('gateway_prepare', ROOT / 'scripts/prepare-container-gateway-source.py')
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
NETWORKING = '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
PORTABLE = 'URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)'
ADAPTED = 'URLResponse(url: URL(fileURLWithPath: "/"), mimeType: nil, expectedContentLength: 0, textEncodingName: nil)'


class PrepareXTests(unittest.TestCase):
    def source(self, directory, content):
        root = Path(directory)
        path = root / 'Sources/XGatewayCore/XGatewayLiveExecutor.swift'
        path.parent.mkdir(parents=True)
        path.write_text(content)
        return root, path

    def test_legacy_source_adapts_and_repeated_preparation_is_stable(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
            root, path = self.source(directory, 'import Foundation\n' + '\n'.join(['URLResponse()'] * 4))
            PREPARE.prepare_x(root)
            first = path.read_text()
            self.assertEqual(first.count(NETWORKING), 1)
            self.assertEqual(first.count(ADAPTED), 4)
            PREPARE.prepare_x(root)
            self.assertEqual(path.read_text(), first)

    def test_upstream_portable_source_is_unchanged_on_every_run(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
            content = 'import Foundation\n' + NETWORKING + '\n'.join([PORTABLE] * 4)
            root, path = self.source(directory, content)
            PREPARE.prepare_x(root)
            PREPARE.prepare_x(root)
            self.assertEqual(path.read_text(), content)

    def test_unknown_or_partial_portability_drift_fails_without_mutation(self):
        for fallbacks in [['URLResponse()'] * 3, ['URLResponse()'] * 3 + [PORTABLE], [PORTABLE] * 5]:
            with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
                original = 'import Foundation\n' + '\n'.join(fallbacks)
                root, path = self.source(directory, original)
                with self.assertRaises(SystemExit):
                    PREPARE.prepare_x(root)
                self.assertEqual(path.read_text(), original)

    def test_unsupported_import_shape_fails_without_mutation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'tmp') as directory:
            original = 'import Foundation\nimport FoundationNetworking\n' + '\n'.join([PORTABLE] * 4)
            root, path = self.source(directory, original)
            with self.assertRaises(SystemExit):
                PREPARE.prepare_x(root)
            self.assertEqual(path.read_text(), original)


if __name__ == '__main__':
    unittest.main()
