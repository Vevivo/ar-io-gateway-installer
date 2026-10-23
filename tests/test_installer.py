"""Offline tests for the actual installer, using only public test keys and temp files.

Run: python3 -m unittest discover -s tests -v
Optional Compose parsing: ARIO_UPSTREAM_COMPOSE=/path/docker-compose.yaml and
ARIO_COMPOSE_BIN=/path/docker-compose. Only `config --format json` is invoked.
No installer main routine, package installation, Docker daemon or network is used.
"""

import copy
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "install-gateway.sh"
PIN = "6c7006d530355c8f07240e28bebac5c9f6c71b7d"
CORE_IMAGE = "ghcr.io/ar-io/ar-io-core:27b668f978a7a28009097d6df4f19fffe4e3af04"
OBSERVER_IMAGE = "ghcr.io/ar-io/ar-io-observer:c5e98ddcf567598358fa73a0852b6be2cbbd42c4"
# RFC 8032 section 7.1, TEST 1; public test material, never fund these keys.
# https://www.rfc-editor.org/rfc/rfc8032#section-7.1
SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
SEED2 = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
PUBLIC2 = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")


def base58(data):
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    value = int.from_bytes(data, "big")
    digits = ""
    while value:
        value, digit = divmod(value, 58)
        digits = alphabet[digit] + digits
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + digits


ADDRESS = base58(PUBLIC)
ADDRESS2 = base58(PUBLIC2)


def isolated_environment():
    # Do not inherit real wallet/RPC credentials, BASH_ENV or Compose overrides.
    allowed = ("PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "TEMP", "TMP", "LANG")
    return {name: os.environ[name] for name in allowed if name in os.environ}


def function_source(name):
    text = INSTALLER.read_text(encoding="utf-8")
    start = re.search(r"^" + re.escape(name) + r"\(\)\s*\{", text, re.M)
    if start is None:
        raise AssertionError("Installer function missing: " + name)
    next_function = re.search(r"^[a-zA-Z_][a-zA-Z0-9_]*\(\)\s*\{", text[start.end():], re.M)
    end = start.end() + next_function.start() if next_function else len(text)
    return text[start.start():end]


def embedded_converter():
    match = re.search(r"<<'PY'\n(.*?)\nPY\n", function_source("convert_key_material"), re.S)
    if match is None:
        raise AssertionError("Embedded key converter heredoc missing")
    return match[1] + "\n"


def bash_binary():
    explicit = os.environ.get("ARIO_TEST_BASH")
    if explicit:
        return explicit
    git_bash = Path("C:/Program Files/Git/bin/bash.exe")
    if os.name == "nt" and git_bash.is_file():
        return str(git_bash)
    return shutil.which("bash")


def env_values(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            name, value = line.split("=", 1)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[name] = value
    return values


class ConverterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ario-converter-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.converter = self.root / "actual-converter.py"
        self.converter.write_text(embedded_converter(), encoding="utf-8")
        self.target = self.root / "test-wallet" / "key.json"

    def convert(self, material, expected=ADDRESS, target=None):
        return subprocess.run(
            [sys.executable, "-B", str(self.converter), str(target or self.target), expected],
            input=material, text=True, encoding="utf-8", capture_output=True,
            env=isolated_environment(), cwd=self.root, timeout=20,
        )

    def test_rfc8032_seed_is_converted_to_known_public_key(self):
        result = self.convert(json.dumps(list(SEED)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), list(SEED + PUBLIC))
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)

    def test_full_keypair_json_preserves_valid_public_half(self):
        result = self.convert(json.dumps(list(SEED + PUBLIC)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.target.read_text()), list(SEED + PUBLIC))

    def test_base58_seed_and_full_keypair_are_supported(self):
        for raw in (SEED, SEED + PUBLIC):
            with self.subTest(length=len(raw)):
                result = self.convert(base58(raw))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.target.read_text()), list(SEED + PUBLIC))

    def test_corrupted_public_half_cannot_create_a_keyfile(self):
        corrupted = SEED + bytes([PUBLIC[0] ^ 1]) + PUBLIC[1:]
        result = self.convert(json.dumps(list(corrupted)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.target.exists())

    def test_wallet_mismatch_preserves_existing_target_bytes(self):
        self.target.parent.mkdir()
        original = b"existing-file-must-not-change\n"
        self.target.write_bytes(original)
        result = self.convert(json.dumps(list(SEED + PUBLIC)), expected=ADDRESS2)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), original)

    def test_invalid_material_does_not_create_output(self):
        for material in ("", "0OIl", "[1,2,3]", json.dumps([-1] * 32), '{"key":"not-an-array"}'):
            with self.subTest(material=material):
                result = self.convert(material)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.target.exists())

    def test_readonly_mode_validates_without_creating_dash_file(self):
        result = self.convert(json.dumps(list(SEED + PUBLIC)), target="-")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), ADDRESS)
        self.assertFalse((self.root / "-").exists())
        self.assertFalse(self.target.exists())


class InstallerFunctionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = bash_binary()
        if not cls.bash:
            raise unittest.SkipTest("Bash unavailable; set ARIO_TEST_BASH (Git Bash works on Windows)")
        # Refuse to source a version that would run its installer main routine.
        text = INSTALLER.read_text(encoding="utf-8")
        if not re.search(r'if\s+\[\[.*BASH_SOURCE\[0\].*\$0.*\]\]', text):
            raise AssertionError("Sourceability guard missing: refusing to execute installer")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ario-installer-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.node = self.root / "node"
        self.node.mkdir()
        self.helpers = self.root / "helpers"
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self.git_log = self.root / "git-calls.txt"
        self.env = isolated_environment()
        self.env.update({
            "TEST_STUB_DIR": self.fake_bin.as_posix(),
            "INSTALL_DIR": self.node.as_posix(), "HELPER_BIN_DIR": self.helpers.as_posix(),
            "ARNS_ROOT_HOST": "gateway.example.com", "AR_IO_WALLET": ADDRESS,
            "OBSERVER_WALLET": ADDRESS2, "REPORT_DATA_SINK": "turbo",
            "SOLANA_RPC_URL": "https://rpc.example.org/?api-key=offline-test",
            "START_HEIGHT": "1800123", "TEST_GIT_LOG": self.git_log.as_posix(),
            "TEST_GIT_REVISION": PIN,
        })
        for command in ("apt", "apt-get", "docker", "systemctl", "ufw", "nginx", "certbot", "curl", "wget", "sudo", "chown"):
            self.stub(command, 'printf "Blocked live command in offline test\\n" >&2\nexit 97\n')
        self.stub("python3", "exec " + shlex.quote(Path(sys.executable).as_posix()) + ' "$@"\n')
        self.stub("openssl", '[[ "$*" == "rand -hex 32" ]] || exit 97\nprintf "%064d\\n" 0\n')
        self.stub("git", '''printf '%s\\t' "$@" >> "$TEST_GIT_LOG"
printf '\\n' >> "$TEST_GIT_LOG"
while [[ "${1:-}" == "-C" ]]; do shift 2; done
case "${1:-}" in
  clone) mkdir -p "${!#}/.git" ;;
  rev-parse) printf '%s\\n' "$TEST_GIT_REVISION" ;;
  remote) printf '%s\\n' 'https://github.com/ar-io/ar-io-node' ;;
  diff|fetch|checkout) exit 0 ;;
  merge-base) exit "${TEST_NOT_ANCESTOR:-0}" ;;
  *) printf 'Unexpected fake git command\\n' >&2; exit 97 ;;
esac
''')

    def stub(self, name, body):
        path = self.fake_bin / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body, encoding="utf-8", newline="\n")
        path.chmod(0o700)

    def shell(self, command, extra_env=None, input_text=None, source_path=INSTALLER):
        env = dict(self.env)
        env.update(extra_env or {})
        # Set PATH inside Bash: Git Bash otherwise prepends its bundled git.exe
        # while translating Windows PATH. Fail closed before sourcing anything.
        prefix = '''set -euo pipefail
stub_dir="$(cd "$TEST_STUB_DIR" && pwd -P)"
export PATH="$stub_dir:$PATH"
hash -r
for guarded in git docker python3 openssl apt-get systemctl curl; do
  [[ "$(type -P "$guarded")" == "$stub_dir/$guarded" ]] || exit 98
done
source "$1"
'''
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", "-c", prefix + command, "offline-test", source_path.as_posix()],
            cwd=self.root, env=env, input=input_text, text=True, encoding="utf-8",
            errors="replace", capture_output=True, timeout=30,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def write_fresh_env(self):
        self.assert_success(self.shell("write_env"))
        return self.node / ".env"

    def git_calls(self):
        return [line.rstrip("\t").split("\t") for line in self.git_log.read_text().splitlines()]

    def test_main_is_not_run_when_sourced(self):
        result = self.shell("printf 'library-only\\n'")
        self.assert_success(result)
        self.assertEqual(result.stdout, "library-only\n")
        self.assertFalse((self.node / ".env").exists())
        self.assertFalse(self.git_log.exists())

    def test_installer_and_generated_helpers_have_valid_bash_syntax(self):
        syntax = subprocess.run([self.bash, "-n", INSTALLER.as_posix()], capture_output=True, text=True, timeout=20)
        self.assert_success(syntax)
        self.assert_success(self.shell("write_helpers"))
        required = {"gateway-update", "gateway-restart", "gateway-logs", "gateway-status", "gateway-check", "gateway-x402-check", "gateway-enable-x402", "gateway-balance", "gateway-observer-check", "gateway-help", "gateway-renew-cert"}
        self.assertTrue(required.issubset({path.name for path in self.helpers.iterdir()}))
        for helper in sorted(self.helpers.glob("gateway-*")):
            with self.subTest(helper=helper.name):
                syntax = subprocess.run([self.bash, "-n", helper.as_posix()], capture_output=True, text=True, timeout=20)
                self.assert_success(syntax)
        update = (self.helpers / "gateway-update").read_text()
        self.assertIn(".installer/install-gateway.sh", update)
        self.assertIn("--upgrade", update)
        self.assertNotIn("git checkout main", update)

    def test_fresh_env_has_required_r85_observer_settings(self):
        values = env_values(self.write_fresh_env())
        for name in ("RUN_OBSERVER", "SUBMIT_CONTRACT_INTERACTIONS"):
            self.assertEqual(values[name], "true")
        self.assertEqual(values["REPORT_DATA_SINK"], "turbo")
        self.assertEqual(values["SOLANA_KEYPAIR_PATH"], f"/app/wallets/{ADDRESS}.json")
        for name in ("OBSERVER_KEYPAIR_PATH", "SOLANA_UPLOAD_KEYPAIR_PATH"):
            self.assertEqual(values[name], f"/app/wallets/{ADDRESS2}.json")
        self.assertEqual(values["START_HEIGHT"], "1800123")
        self.assertEqual(values["CORE_LOG_LEVEL"], "info")
        self.assertEqual(values["OBSERVER_LOG_LEVEL"], "info")
        self.assertEqual(values["ENABLE_EPOCH_CRANKING"], "false")
        self.assertFalse(any(name.endswith("_PRIVATE_KEY") and value for name, value in values.items()))

    def test_fresh_install_refuses_to_replace_existing_env(self):
        target = self.node / ".env"
        original = b"ADMIN_API_KEY=offline-preserve-test\nCUSTOM_SETTING=retain\n"
        target.write_bytes(original)
        result = self.shell("write_env")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), original)

    def legacy_env(self, extra=""):
        original = (
            "# existing operator choices\nADMIN_API_KEY=offline-preserve-test\n"
            "RUN_OBSERVER=true\nLOG_LEVEL=debug\nSTART_HEIGHT=1900123\n"
            "ARNS_CACHE_TTL_MS=7200000\nCUSTOM_FUTURE_OPTION=preserve-me\n"
            f"OBSERVER_KEYPAIR_PATH=/app/wallets/{ADDRESS2}.json\n" + extra
        ).encode()
        (self.node / ".env").write_bytes(original)
        return original

    def test_migration_preserves_choices_and_is_idempotent(self):
        original = self.legacy_env()
        self.assert_success(self.shell("migrate_env"))
        target = self.node / ".env"
        migrated = target.read_bytes()
        self.assertTrue(migrated.startswith(original))
        backups = list(self.node.glob(".env.backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        values = env_values(target)
        self.assertEqual(values["ADMIN_API_KEY"], "offline-preserve-test")
        self.assertEqual(values["CUSTOM_FUTURE_OPTION"], "preserve-me")
        self.assertEqual(values["START_HEIGHT"], "1900123")
        self.assertEqual(values["CORE_LOG_LEVEL"], "debug")
        self.assertEqual(values["OBSERVER_LOG_LEVEL"], "debug")
        self.assertEqual(values["ARNS_CACHE_TTL_SECONDS"], "7200")
        self.assertEqual(values["SOLANA_UPLOAD_KEYPAIR_PATH"], "${OBSERVER_KEYPAIR_PATH}")
        self.assertEqual(values["SUBMIT_CONTRACT_INTERACTIONS"], "true")
        self.assert_success(self.shell("migrate_env"))
        self.assertEqual(target.read_bytes(), migrated)
        self.assertEqual(len(list(self.node.glob(".env.backup.*"))), 1)

    def test_migration_refuses_disabled_observer_or_submission_without_writes(self):
        for flag in ("RUN_OBSERVER", "SUBMIT_CONTRACT_INTERACTIONS"):
            with self.subTest(flag=flag):
                original = self.legacy_env(f"{flag}=false\n")
                result = self.shell("migrate_env")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.node / ".env").read_bytes(), original)
                self.assertFalse(list(self.node.glob(".env.backup.*")))

    def test_clone_uses_fixed_r85_tag_and_checks_commit(self):
        self.node.rmdir()
        self.assert_success(self.shell("clone_node"))
        calls = self.git_calls()
        self.assertIn(["clone", "--branch", "r85", "https://github.com/ar-io/ar-io-node", self.node.as_posix()], calls)
        self.assertIn(["rev-parse", "HEAD"], calls)
        self.assertNotIn("main", [argument for call in calls for argument in call])
        self.assert_success(self.shell('[[ "$ARIO_COMMIT" == ' + shlex.quote(PIN) + " ]]"))

    def test_wrong_release_commit_is_rejected(self):
        self.node.rmdir()
        result = self.shell("clone_node", {"TEST_GIT_REVISION": "0" * 40})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected upstream commit", result.stderr)

    def test_update_detaches_only_at_verified_release(self):
        (self.node / ".git").mkdir()
        self.assert_success(self.shell("clone_node"))
        calls = self.git_calls()
        self.assertIn(["fetch", "origin", "refs/tags/r85"], calls)
        self.assertIn(["merge-base", "--is-ancestor", "HEAD", PIN], calls)
        self.assertIn(["checkout", "--detach", PIN], calls)

    def test_update_refuses_downgrade_without_checkout(self):
        (self.node / ".git").mkdir()
        result = self.shell("clone_node", {"TEST_NOT_ANCESTOR": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "checkout" for call in self.git_calls()))

    def test_domain_input_rejects_shell_metacharacters(self):
        for domain in ("example.com;touch injected", "*.example.com", "example..com", "example.com."):
            with self.subTest(domain=domain):
                result = self.shell("validate_domain " + shlex.quote(domain))
                self.assertNotEqual(result.returncode, 0)
        self.assert_success(self.shell("validate_domain gateway.example.com"))
        self.assertFalse((self.root / "injected").exists())

    def test_existing_key_validation_requires_native_64_byte_format(self):
        target = self.node / "key.json"
        seed_only = json.dumps(list(SEED)).encode()
        target.write_bytes(seed_only)
        command = "validate_key_file " + shlex.quote(target.as_posix()) + " " + shlex.quote(ADDRESS)
        self.assertNotEqual(self.shell(command).returncode, 0)
        self.assertEqual(target.read_bytes(), seed_only)
        complete = json.dumps(list(SEED + PUBLIC)).encode()
        target.write_bytes(complete)
        self.assert_success(self.shell(command))
        self.assertEqual(target.read_bytes(), complete)

    def test_pending_setup_dispatches_to_resume_instead_of_upgrade(self):
        (self.node / ".env").write_bytes(b"KEEP_EXISTING=true\n")
        (self.node / ".installer").mkdir()
        (self.node / ".installer" / "setup-pending").touch()
        result = self.shell('''require_root() { :; }
validate_install_dir() { :; }
resume_gateway() { printf 'resume-only\\n'; }
upgrade_gateway() { printf 'incorrect-upgrade\\n'; return 99; }
main
''')
        self.assert_success(result)
        self.assertEqual(result.stdout, "resume-only\n")
        self.assertEqual((self.node / ".env").read_bytes(), b"KEEP_EXISTING=true\n")

    def test_new_install_validates_keys_before_writing_env(self):
        trace = self.root / "dispatch.txt"
        result = self.shell('''record() { printf '%s\\n' "$1" >> "$TEST_TRACE"; }
require_root() { :; }
validate_install_dir() { :; }
header() { :; }
collect_config() { :; }
install_packages() { record packages-stub; }
install_docker() { record docker-stub; }
clone_node() { record clone-stub; }
configure_wallet() { record "key:$1"; }
write_env() { [[ -f "$INSTALL_DIR/.installer/setup-pending" ]]; record env; }
save_installer() { record save-stub; }
start_gateway() { record start-stub; }
configure_firewall_ssl_nginx() { record tls-stub; }
write_helpers() { record helpers-stub; }
finish() { record finish-stub; }
main
''', {"TEST_TRACE": trace.as_posix()})
        self.assert_success(result)
        events = trace.read_text().splitlines()
        self.assertLess(events.index("key:main/operator"), events.index("env"))
        self.assertLess(events.index("key:observer"), events.index("env"))
        self.assertLess(events.index("tls-stub"), events.index("finish-stub"))
        self.assertFalse((self.node / ".installer" / "setup-pending").exists())

    def test_process_substitution_can_save_a_self_contained_updater(self):
        result = self.shell('''source <(cat "$1")
CDP_SECRET_VALUE='offline-secret-must-not-be-saved'
save_installer
''')
        self.assert_success(result)
        saved = self.node / ".installer" / "install-gateway.sh"
        text = saved.read_text(encoding="utf-8")
        self.assertNotIn("offline-secret-must-not-be-saved", text)
        self.assertNotIn("rpc.example.org", text)
        self.assertIn(PIN, text)
        syntax = subprocess.run([self.bash, "-n", saved.as_posix()], capture_output=True, text=True, timeout=20)
        self.assert_success(syntax)
        boundary = "\nrequire_root\nvalidate_install_dir\n"
        self.assertIn(boundary, text)
        library = self.root / "saved-library.sh"
        library.write_text(text.rsplit(boundary, 1)[0] + "\n", encoding="utf-8", newline="\n")
        command = '''for name in upgrade_gateway refresh_helpers migrate_env validate_observer_config validate_key_file convert_key_material clone_node write_helpers save_installer read_env_value; do
  declare -F "$name" >/dev/null || exit 99
done
DOMAIN=gateway.example.com
write_helpers
'''
        self.assert_success(self.shell(command, source_path=library))
        self.assertTrue((self.helpers / "gateway-update").is_file())

    def test_env_comments_are_parsed_without_executing_values(self):
        original = (
            'RUN_OBSERVER=true # enabled\n'
            'ARNS_ROOT_HOST="gateway.example.com" # domain\n'
            "LOG_LEVEL='debug' # retained level\n"
            'CUSTOM_LITERAL=$(touch injected)\n'
        ).encode()
        target = self.node / ".env"
        target.write_bytes(original)
        result = self.shell("read_env_value ARNS_ROOT_HOST")
        self.assert_success(result)
        self.assertEqual(result.stdout, "gateway.example.com")
        result = self.shell("read_env_value CUSTOM_LITERAL")
        self.assert_success(result)
        self.assertEqual(result.stdout, "$(touch injected)")
        self.assert_success(self.shell("migrate_env"))
        self.assertTrue(target.read_bytes().startswith(original))
        self.assertEqual(env_values(target)["CORE_LOG_LEVEL"], "debug")
        self.assertFalse((self.root / "injected").exists())
        self.assertFalse((self.node / "injected").exists())

    def test_actual_official_compose_accepts_generated_env_without_daemon(self):
        upstream = Path(os.environ.get("ARIO_UPSTREAM_COMPOSE", REPO.parent / "upstream-ar-io-node-r85" / "docker-compose.yaml"))
        default_compose = REPO.parent / "starter-validation" / "docker-compose.exe"
        compose = os.environ.get("ARIO_COMPOSE_BIN") or (str(default_compose) if default_compose.is_file() else shutil.which("docker-compose"))
        if not upstream.is_file() or not compose:
            self.skipTest("Optional: provide local R85 Compose YAML and ARIO_COMPOSE_BIN; no downloads are performed")
        env_file = self.write_fresh_env()
        result = subprocess.run(
            [compose, "--project-directory", str(self.node), "--env-file", str(env_file), "-f", str(upstream), "config", "--format", "json"],
            env=isolated_environment(), cwd=self.node, capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, "Compose config failed; raw configuration is intentionally not printed")
        services = json.loads(result.stdout)["services"]
        self.assertEqual(services["core"]["image"], CORE_IMAGE)
        self.assertEqual(services["observer"]["image"], OBSERVER_IMAGE)
        observer = services["observer"]["environment"]
        self.assertEqual(observer["RUN_OBSERVER"], "true")
        self.assertEqual(observer["SUBMIT_CONTRACT_INTERACTIONS"], "true")
        self.assertEqual(observer["SOLANA_KEYPAIR_PATH"], f"/app/wallets/{ADDRESS}.json")
        self.assertEqual(observer["SOLANA_UPLOAD_KEYPAIR_PATH"], f"/app/wallets/{ADDRESS2}.json")
        self.assertTrue({"index-swarm", "index-swarm-engine", "index-swarm-engine-init"}.issubset(services))
        config = json.loads(result.stdout)
        config_file = self.root / "compose-fixture.json"
        config_file.write_text(json.dumps(config), encoding="utf-8")
        wallet_dir = self.node / "wallets"
        wallet_dir.mkdir()
        for address, secret in ((ADDRESS, SEED + PUBLIC), (ADDRESS2, SEED2 + PUBLIC2)):
            target = wallet_dir / (address + ".json")
            target.write_text(json.dumps(list(secret)), encoding="utf-8")
            target.chmod(0o600)
        self.stub("docker", '''[[ "$*" == 'compose config --format json' ]] || exit 97
cat "$TEST_COMPOSE_JSON"
''')
        extra = {"TEST_COMPOSE_JSON": config_file.as_posix()}
        self.assert_success(self.shell("validate_observer_config", extra))
        for field, value in (("RUN_OBSERVER", "false"), ("SOLANA_UPLOAD_KEYPAIR_PATH", "")):
            with self.subTest(rejected_field=field):
                invalid = copy.deepcopy(config)
                invalid["services"]["observer"]["environment"][field] = value
                config_file.write_text(json.dumps(invalid), encoding="utf-8")
                self.assertNotEqual(self.shell("validate_observer_config", extra).returncode, 0)
        invalid = copy.deepcopy(config)
        invalid["services"]["core"]["image"] = "ghcr.io/ar-io/ar-io-core:latest"
        config_file.write_text(json.dumps(invalid), encoding="utf-8")
        self.assertNotEqual(self.shell("validate_observer_config", extra).returncode, 0)


if __name__ == "__main__":
    unittest.main()
