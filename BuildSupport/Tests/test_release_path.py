from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleasePathTests(unittest.TestCase):
    def test_release_uses_one_build_and_the_canonical_publisher(self) -> None:
        build = (ROOT / "Scripts/build-device-ipa.sh").read_text()
        publish = (ROOT / "Scripts/publish-builds-lan.sh").read_text()
        release = (ROOT / "Scripts/release.sh").read_text()

        self.assertIn("ios-build-support", build)
        self.assertIn("SOURCE_REVISION", build)
        self.assertIn("manifest.plist", build)
        self.assertIn("build-device-ipa.sh", release)
        self.assertIn("publish-builds-lan.sh", release)
        self.assertIn(
            "/Volumes/RunnerCache/code/builds-native/Scripts/upload-builds-lan-api.py",
            publish,
        )
        self.assertIn('API_BASE_URL="https://api.builds.lan"', publish)
        self.assertIn("--api-url \"$API_BASE_URL\"", publish)
        self.assertIn("--platform ios", publish)
        self.assertIn("--manifest \"$MANIFEST\"", publish)
        self.assertIn("--token-file \"$UPLOAD_TOKEN_FILE\"", publish)

    def test_release_path_has_no_retired_publication_routes(self) -> None:
        scripts = "\n".join(
            (ROOT / f"Scripts/{name}").read_text()
            for name in (
                "build-device-ipa.sh",
                "publish-builds-lan.sh",
                "release.sh",
            )
        )

        self.assertNotIn("builds.home.javisoto.es", scripts)
        self.assertNotIn("scp ", scripts)
        self.assertNotIn("ssh ", scripts)

    def test_source_revision_is_embedded_in_the_release_info_plist(self) -> None:
        info = (ROOT / "Config/Info.plist").read_text()
        project = (ROOT / "Config/Project.xcconfig").read_text()
        build = (ROOT / "Scripts/build-device-ipa.sh").read_text()

        self.assertIn("CFBundleSourceRevision", info)
        self.assertIn("$(DEVICE_HUB_SOURCE_REVISION)", info)
        self.assertIn("DEVICE_HUB_SOURCE_REVISION =", project)
        self.assertIn('DEVICE_HUB_SOURCE_REVISION="$SOURCE_REVISION"', build)


if __name__ == "__main__":
    unittest.main()
