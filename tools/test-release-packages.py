import importlib.util
from pathlib import Path
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release_assets', PROJECT / 'scripts/prepare-release-assets.py')
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleasePackageTests(unittest.TestCase):
    def test_notes_install_native_platform_and_kernel_without_npu_archives(self):
        output = PROJECT.parent / 'build/caihong-release-package-tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as temporary:
            root = Path(temporary)
            cases = (
                ('archlinuxarm', ('caihong-platform-test-1-aarch64.pkg.tar.zst',
                                  'linux-caihong-test-1-aarch64.pkg.tar.zst'), 'pacman'),
                ('armada', ('caihong-platform-test-1.aarch64.rpm',
                            'linux-caihong-test-1.aarch64.rpm'), 'dnf'),
                ('debian', ('caihong-platform_1_arm64.deb',
                            'linux-caihong_1_arm64.deb'), 'apt'),
            )
            for distribution, names, manager in cases:
                with self.subTest(distribution=distribution):
                    assets = [root / name for name in names]
                    image = root / 'rootfs.img'
                    compressed = root / 'rootfs.img.zst'
                    for path in (*assets, image, compressed):
                        path.write_bytes(b'test')
                    notes = root / f'{distribution}.md'
                    RELEASE.write_release_notes(
                        notes, distribution, 'test', assets,
                        {path.name: '0' * 64 for path in assets}, image, '0' * 64,
                        compressed, '0' * 64, [compressed], {},
                        {'format': 'android-sparse-ext4', 'logical_bytes': 4096,
                         'filesystem_label': 'linux'})
                    contents = notes.read_text()
                    self.assertIn('sudo ' + manager, contents)
                    self.assertIn('./' + assets[0].name, contents)
                    self.assertIn('./' + assets[1].name, contents)
                    self.assertNotIn('install-caihong-platform', contents)
                    self.assertNotIn('caihong-npu-', contents)
                    self.assertIn('fully upgrade', contents)

    def test_rocknix_notes_reflash_instead_of_using_a_package_manager(self):
        output = PROJECT.parent / 'build/caihong-release-package-tests'
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output) as temporary:
            root = Path(temporary)
            assets = [root / 'caihong-platform-test-1-rocknix.tar.zst']
            image = root / 'rootfs.img'
            compressed = root / 'rootfs.img.zst'
            for path in (*assets, image, compressed):
                path.write_bytes(b'test')
            notes = root / 'rocknix.md'
            RELEASE.write_release_notes(
                notes, 'rocknix', 'test', assets,
                {path.name: '0' * 64 for path in assets}, image, '0' * 64,
                compressed, '0' * 64, [compressed], {},
                {'format': 'android-sparse-ext4', 'logical_bytes': 4096,
                 'filesystem_label': 'linux'})
            contents = notes.read_text()
            self.assertIn('no package manager', contents)
            self.assertIn(assets[0].name, contents)
            self.assertIn('flashing the new rootfs image', contents)
            self.assertNotIn('sudo apt', contents)
            self.assertNotIn('install-caihong-platform', contents)


if __name__ == '__main__':
    unittest.main()
