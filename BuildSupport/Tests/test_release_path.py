from __future__ import annotations

import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile


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
        self.assertNotIn("--api-url", publish)
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

    def test_device_release_uses_current_xcode_and_external_derived_data(self) -> None:
        build = (ROOT / "Scripts/build-device-ipa.sh").read_text()

        self.assertIn('/usr/bin/xcode-select -p', build)
        self.assertNotIn("Xcode-27.0.0-beta.3", build)
        self.assertIn(
            '"${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData}"',
            build,
        )
        self.assertIn("/Volumes/RunnerCache/DerivedData/javi", build)
        self.assertIn("df -P", build)

    def test_apple_signing_uses_codex_secret_private_fd_by_default(self) -> None:
        build = (ROOT / "Scripts/build-device-ipa.sh").read_text()

        self.assertIn('APPLE_API_KEY_JSON="${APPLE_API_KEY_JSON:-}"', build)
        self.assertNotIn("apple_api_key.json", build)
        self.assertIn('ios_fetch_enabled_ios_device_udids "$APPLE_API_KEY_JSON"', build)
        self.assertIn('"$APPLE_API_KEY_JSON"', build)

    def test_profile_request_passes_the_local_signing_identity(self) -> None:
        build = (ROOT / "Scripts/build-device-ipa.sh").read_text()
        call = re.search(r'(?ms)^PROFILE_UUID="\$\(ios_ensure_profile_uuid \\\n.*?\)"', build)
        self.assertIsNotNone(call)
        shell = '\n'.join((
            'set -euo pipefail',
            'APP_BUNDLE_ID=es.javisoto.DeviceHub',
            'TARGET_DEVICE_UDIDS=synthetic-device',
            'APPLE_API_KEY_JSON=""',
            'SHARED_IOS_SUPPORT_DIR=/synthetic-support',
            'TEAM_ID=synthetic-team',
            'CERTIFICATE="Synthetic Distribution Identity"',
            'ios_ensure_profile_uuid() { [[ "${8:-}" == "$CERTIFICATE" ]] || return 64; printf "synthetic-profile\\n"; }',
            call.group(),
            'printf "%s\\n" "$PROFILE_UUID"',
        ))
        result = subprocess.run(['/bin/bash', '-c', shell], capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'synthetic-profile\n')

    def test_xcodebuild_keeps_raw_and_formatted_output_and_result_bundle(self) -> None:
        build = (ROOT / "Scripts/build-device-ipa.sh").read_text()

        self.assertIn('"$raw_log"', build)
        self.assertIn("xcbeautify", build)
        self.assertIn('statuses=("${PIPESTATUS[@]}")', build)
        self.assertIn("-resultBundlePath", build)
        self.assertNotIn("-quiet archive", build)

    def test_build_output_fixtures_keep_logs_paths_and_original_status(self) -> None:
        with tempfile.TemporaryDirectory(prefix="device-hub-xcode-output-") as scratch:
            scratch_root = Path(scratch)
            success = self._run_build_output_fixture(
                scratch_root,
                "success",
                "mkdir -p \"$FIXTURE_RESULT\"; printf 'warning: fixture warning\\n'; exit 0",
            )
            self.assertEqual(success[0].returncode, 0, success[0].stderr)
            self.assertTrue(success[2].is_dir())
            self.assertEqual(success[1].read_text(), "warning: fixture warning\n")
            self.assertEqual(
                success[0].stdout,
                "formatted:warning: fixture warning\nFUNCTION_STATUS=0\n",
            )
            self.assertIn("XCODEBUILD_OK action=success", success[0].stderr)
            self.assertIn(str(success[2]), success[0].stderr)

            compile_failure = self._run_build_output_fixture(
                scratch_root,
                "compile",
                "printf 'warning: compile fixture\\nerror: compile failed\\n'; exit 65",
            )
            self.assertEqual(compile_failure[0].returncode, 0)
            self.assertIn("FUNCTION_STATUS=65", compile_failure[0].stdout)
            self.assertEqual(
                compile_failure[1].read_text(),
                "warning: compile fixture\nerror: compile failed\n",
            )
            self.assertIn("formatted:error: compile failed", compile_failure[0].stdout)
            self.assertIn("xcodebuild_exit=65", compile_failure[0].stderr)
            self.assertIn(str(compile_failure[2]), compile_failure[0].stderr)

            test_failure = self._run_build_output_fixture(
                scratch_root,
                "tests",
                "printf 'Test Suite fixture failed\\n'; exit 65",
            )
            self.assertEqual(test_failure[0].returncode, 0)
            self.assertIn("FUNCTION_STATUS=65", test_failure[0].stdout)
            self.assertEqual(
                test_failure[1].read_text(), "Test Suite fixture failed\n"
            )
            self.assertIn("formatted:Test Suite fixture failed", test_failure[0].stdout)
            self.assertIn("xcodebuild_exit=65", test_failure[0].stderr)
            self.assertIn(str(test_failure[2]), test_failure[0].stderr)

    def test_publisher_uses_builds_secret_private_fd_by_default(self) -> None:
        with tempfile.TemporaryDirectory(prefix="device-hub-release-test-") as scratch:
            scratch_root = Path(scratch)
            repo = scratch_root / "repo"
            scripts = repo / "Scripts"
            scripts.mkdir(parents=True)
            shutil.copy2(ROOT / "Scripts/publish-builds-lan.sh", scripts)
            self._init_clean_fixture_repo(repo)

            revision = subprocess.check_output(
                ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
            ).strip()
            fixture = scratch_root / "fixtures"
            tools = scratch_root / "tools"
            fixture.mkdir()
            tools.mkdir()

            ipa = fixture / "DeviceHub.ipa"
            info = {
                "CFBundleIdentifier": "es.javisoto.DeviceHub",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "42",
                "CFBundleSourceRevision": revision,
            }
            with ZipFile(ipa, "w") as archive:
                archive.writestr(
                    "Payload/DeviceHub.app/Info.plist",
                    plistlib.dumps(info),
                )
            (fixture / "manifest.plist").write_text("fixture manifest\n")
            (fixture / "version.txt").write_text("1.0.0\n42\n")
            (fixture / "source-revision.txt").write_text(f"{revision}\n")
            notes = fixture / "release-notes.md"
            notes.write_text("Full-screen remote device view and working keyboard.\n")
            ca_file = fixture / "root-ca.pem"
            ca_file.write_text("synthetic public CA fixture\n")

            secret_file = fixture / "secret.json"
            secret_file.write_text('{"token":"synthetic-builds-token"}')
            upload_log = fixture / "upload.json"
            upload_sha = fixture / "upload.sha256"
            fake_secret = tools / "codex-secret"
            fake_secret.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "[[ \"${CODEX_AGENT:-}\" == 1 ]]\n"
                "[[ \"${1:-}\" == run ]]\n"
                "[[ \"${2:-}\" == builds_lan_upload_access ]]\n"
                "[[ \"${3:-}\" == -- ]]\n"
                "shift 3\n"
                "exec 9<\"$PUBLISH_FIXTURE_SECRET_FILE\"\n"
                "CODEX_SECRET_FD=9 exec \"$@\"\n"
            )
            fake_secret.chmod(0o755)

            fake_uploader = tools / "fake-uploader.py"
            fake_uploader.write_text(
                "from __future__ import annotations\n"
                "import hashlib, json, os, sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "assert '--token-file' not in args\n"
                "assert '--api-url' not in args\n"
                "assert args[args.index('--ca-file') + 1] == os.environ['BUILDS_LAN_CA_FILE']\n"
                "assert args[args.index('--platform') + 1] == 'ios'\n"
                "artifact = Path(args[args.index('--artifact') + 1])\n"
                "token = json.load(os.fdopen(int(os.environ['CODEX_SECRET_FD'])))['token']\n"
                "assert token == 'synthetic-builds-token'\n"
                "digest = hashlib.sha256(artifact.read_bytes()).hexdigest()\n"
                "Path(os.environ['PUBLISH_FIXTURE_SHA']).write_text(digest)\n"
                "Path(os.environ['PUBLISH_FIXTURE_LOG']).write_text(json.dumps({\n"
                "    'token_received': bool(token), 'token_value_logged': False, 'args': args\n"
                "}))\n"
                "print(json.dumps({'bundle_id': 'es.javisoto.DeviceHub',\n"
                "    'platform': 'ios', 'icon_url': 'https://builds.lan/icon.png',\n"
                "    'build': {'ipa_url': 'https://builds.lan/device.ipa',\n"
                "    'manifest_url': 'https://builds.lan/manifest.plist', 'sha256': digest}}))\n"
            )

            fake_curl = tools / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "output = Path(args[args.index('--output') + 1])\n"
                "digest = Path(os.environ['PUBLISH_FIXTURE_SHA']).read_text()\n"
                "catalog = json.dumps({'apps': [{'bundle_id': 'es.javisoto.DeviceHub',\n"
                "    'builds': [{'sha256': digest}]}]})\n"
                "output.write_text(catalog)\n"
                "Path(os.environ['PUBLISH_FIXTURE_CATALOG']).write_text(catalog)\n"
            )
            fake_curl.chmod(0o755)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(scratch_root / "home"),
                    "PATH": f"{tools}:{env['PATH']}",
                    "BUILDS_LAN_UPLOAD_CLIENT": str(fake_uploader),
                    "CODEX_SECRET_BIN": str(fake_secret),
                    "BUILDS_LAN_CA_FILE": str(ca_file),
                    "PUBLISH_FIXTURE_SECRET_FILE": str(secret_file),
                    "PUBLISH_FIXTURE_LOG": str(upload_log),
                    "PUBLISH_FIXTURE_SHA": str(upload_sha),
                    "PUBLISH_FIXTURE_CATALOG": str(fixture / "catalog.json"),
                }
            )
            result = subprocess.run(
                [
                    "/bin/bash",
                    str(scripts / "publish-builds-lan.sh"),
                    str(ipa),
                    "--release-notes-file",
                    str(notes),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Builds.lan catalog contains", result.stdout)
            self.assertIn("https://api.builds.lan/v1/catalog", result.stdout)
            upload = json.loads(upload_log.read_text())
            self.assertTrue(upload["token_received"])
            self.assertFalse(upload["token_value_logged"])
            self.assertNotIn("synthetic-builds-token", result.stdout + result.stderr)

    @staticmethod
    def _init_clean_fixture_repo(repo: Path) -> None:
        subprocess.run(["git", "-C", str(repo), "init"], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.name", "Release Fixture"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.email", "release-fixture@example.invalid"],
            check=True,
        )
        subprocess.run(["git", "-C", str(repo), "add", "Scripts"], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "commit", "-m", "fixture publisher"],
            check=True,
            capture_output=True,
        )

    @staticmethod
    def _run_build_output_fixture(
        scratch: Path, action: str, command: str
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
        build_script = (ROOT / "Scripts/build-device-ipa.sh").read_text()
        match = re.search(r"(?ms)^run_xcodebuild\(\) \{.*?^\}", build_script)
        if match is None:
            raise AssertionError("release script has no run_xcodebuild helper")

        formatter = scratch / "fixture-xcbeautify"
        formatter.write_text(
            "#!/bin/bash\nset -euo pipefail\n/usr/bin/sed 's/^/formatted:/'\n"
        )
        formatter.chmod(0o755)
        raw_log = scratch / f"{action}.log"
        result_bundle = scratch / f"{action}.xcresult"
        shell = "\n".join(
            (
                "set -euo pipefail",
                f"XCBEAUTIFY_BIN={shlex.quote(str(formatter))}",
                match.group(),
                "set +e",
                "run_xcodebuild "
                f"{shlex.quote(action)} {shlex.quote(str(raw_log))} "
                f"{shlex.quote(str(result_bundle))} /bin/bash -c {shlex.quote(command)}",
                "status=$?",
                "set -e",
                'printf "FUNCTION_STATUS=%s\\n" "$status"',
            )
        )
        env = os.environ.copy()
        env["FIXTURE_RESULT"] = str(result_bundle)
        result = subprocess.run(
            ["/bin/bash", "-c", shell],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        return result, raw_log, result_bundle


if __name__ == "__main__":
    unittest.main()
