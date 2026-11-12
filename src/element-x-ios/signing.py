#!/usr/bin/env python3
"""Prepare and verify CHIICH manual signing; never creates Apple portal assets."""
import argparse
import base64
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from urllib.error import URLError
import zipfile

TEAM = "RM8GR3A69Q"
APP = "one.chiich.app"
GROUP = "group.one.chiich"
TARGETS = {
    "ElementX": (APP, "CHIICH_IOS_PROFILE_APP_BASE64"),
    "NSE": (APP + ".nse", "CHIICH_IOS_PROFILE_NSE_BASE64"),
    "ShareExtension": (APP + ".shareextension", "CHIICH_IOS_PROFILE_SHARE_BASE64"),
}
CAPABILITIES = {
    "ElementX": {"com.apple.developer.usernotifications.communication": True},
    # Explicit first-device policy: push is not connected in this trial.
    # Keep native NSE code; its unused filtering entitlement needs Apple approval
    # before a later release enables APNs and the CHIICH pusher.
    "NSE": {},
    "ShareExtension": {},
}
PROFILE_DIR = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
ASC_KEY_SECRETS = ("CHIICH_ASC_PRIVATE_KEY_P8", "CHIICH_ASC_PRIVATE_KEY_P8_BASE64")
TRIAL = "disabled-trial"
LINKS_ONLY = "links-only"
SERVICES_ENABLED = "services-enabled"
SERVICES_CONFIG = Path(__file__).resolve().with_name("services.json")
SERVICES_INFO_KEY = "CHIICHNativeServices"
APS = "aps-environment"
FILTERING = "com.apple.developer.usernotifications.filtering"
ASSOCIATED_DOMAINS = "com.apple.developer.associated-domains"
SERVICE_ENTITLEMENTS = (APS, FILTERING, ASSOCIATED_DOMAINS)
SERVICE_KEYS = {
    "schema_version", "mode", "team_id", "bundle_id", "pusher_app_id",
    "apns_environment", "gateway_base_url", "render_service_id",
    "gateway_ownership_verified", "universal_links",
}
LINK_KEYS = {"schema_version", "mode", "team_id", "bundle_id", "universal_links"}
ASSOCIATION_URL = "https://chiich.one/.well-known/apple-app-site-association"
ASSOCIATION_FIXTURE = Path(__file__).resolve().parent / "fixtures/chiich-apple-app-site-association.json"
ASSOCIATION_MAX_BYTES = 128 * 1024
GATEWAY_DECLARATION = 'private(set) var pushGatewayBaseURL: URL = InfoPlistReader.main.chiichPushGatewayBaseURL ?? "https://notifications.invalid"'
ONBOARDING_PREFERENCE = "@UserPreference(defaultValue: InfoPlistReader.main.chiichPushGatewayBaseURL == nil)\n    var hasRunNotificationPermissionsOnboarding: Bool"
ACCOUNT_PREFERENCE = "@UserPreference(defaultValue: InfoPlistReader.main.chiichPushGatewayBaseURL != nil)\n    var enableNotifications: Bool"


def validate_services(services):
    """Validate a reviewed, non-secret configuration; never discover a gateway.

    The ownership field records the operator's check of this exact Render
    service/origin. Local parsing cannot prove ownership or APNs delivery.
    The real services.json is deliberately absent until that check is complete.
    """
    if services is None:
        return None
    if isinstance(services, dict) and services.get("mode") == LINKS_ONLY:
        expected = {"mode": LINKS_ONLY, "team_id": TEAM, "bundle_id": APP,
                    "universal_links": True}
        if (set(services) != LINK_KEYS or type(services.get("schema_version")) is not int
                or services["schema_version"] != 1
                or services.get("universal_links") is not True
                or any(services.get(key) != value for key, value in expected.items())):
            raise ValueError("Links-only configuration must contain only the reviewed CHIICH identity and enabled links")
        return dict(services)
    if not isinstance(services, dict) or set(services) != SERVICE_KEYS:
        raise ValueError("Services configuration must contain exactly the documented non-secret fields")
    expected = {"mode": SERVICES_ENABLED, "team_id": TEAM, "bundle_id": APP,
                "pusher_app_id": APP + ".ios.prod", "apns_environment": "production"}
    if (type(services.get("schema_version")) is not int or services["schema_version"] != 1
            or any(services.get(key) != value for key, value in expected.items())):
        raise ValueError("Services configuration does not match the CHIICH production identity/schema")
    if (services.get("gateway_ownership_verified") is not True
            or type(services.get("universal_links")) is not bool):
        raise ValueError("Gateway ownership must be verified; universal_links must be an explicit boolean")
    service_id = services.get("render_service_id")
    if not isinstance(service_id, str) or not re.fullmatch(r"srv-[a-z0-9]{20,32}", service_id):
        raise ValueError("Services configuration needs the verified Render service ID")
    value = services.get("gateway_base_url")
    try:
        if not isinstance(value, str) or not 1 <= len(value) <= 300:
            raise ValueError()
        parsed = urlsplit(value)
        host = parsed.hostname or ""
        if (parsed.scheme != "https" or value != f"https://{host}"
                or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.onrender\.com", host)):
            raise ValueError()
    except ValueError:
        raise ValueError("Push gateway must be the verified canonical Render HTTPS origin, without path, port or credentials") from None
    return dict(services)


def load_services(mode, path=None):
    if mode == TRIAL:
        if path is not None:
            raise ValueError("A services configuration is only accepted with explicit services-enabled mode")
        return None
    if mode == LINKS_ONLY:
        if path is not None:
            raise ValueError("Links-only mode uses the fixed reviewed CHIICH identity, not a services file")
        return validate_services({"schema_version": 1, "mode": LINKS_ONLY,
                                  "team_id": TEAM, "bundle_id": APP, "universal_links": True})
    if mode != SERVICES_ENABLED:
        raise ValueError("Unknown native services mode")
    path = Path(path) if path is not None else SERVICES_CONFIG
    if path.is_symlink() or path.resolve() != SERVICES_CONFIG.resolve():
        raise ValueError("Enabled services must use the reviewed src/element-x-ios/services.json")
    try:
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 4096:
            raise ValueError()
        payload = path.read_bytes()
        if len(payload) > 4096:
            raise ValueError()
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError()
                result[key] = value
            return result
        configuration = json.loads(payload.decode("utf-8"), object_pairs_hook=unique_object)
    except (OSError, ValueError, UnicodeError):
        raise ValueError("Enabled services need a bounded, valid reviewed services.json; the example is not an activation") from None
    return validate_services(configuration)


def required_capabilities(services):
    services = validate_services(services)
    result = {target: dict(values) for target, values in CAPABILITIES.items()}
    if push_enabled(services):
        result["ElementX"][APS] = "production"
        result["NSE"][FILTERING] = True
    if services is not None and services["universal_links"]:
        result["ElementX"][ASSOCIATED_DOMAINS] = ["applinks:chiich.one"]
    return result


def push_enabled(services):
    return services is not None and services["mode"] == SERVICES_ENABLED


def service_provenance(services):
    services = validate_services(services)
    if services is None:
        return {"push_notifications": TRIAL, "nse_filtering": "omitted-unused-entitlement"}
    if not push_enabled(services):
        return {"push_notifications": TRIAL, "nse_filtering": "omitted-unused-entitlement",
                "native_services": services}
    return {"push_notifications": "enabled-production", "nse_filtering": "required",
            "native_services": services}


class NoAssociationRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def association_json(payload):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("AASA contains duplicate JSON fields")
            result[key] = value
        return result
    if not 0 < len(payload) <= ASSOCIATION_MAX_BYTES:
        raise ValueError("AASA must be a non-empty bounded JSON document")
    try:
        result = json.loads(payload.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, ValueError):
        raise ValueError("AASA must contain valid UTF-8 JSON without duplicate fields") from None
    if not isinstance(result, dict):
        raise ValueError("AASA must contain one association object")
    return result


def verify_live_association(services):
    """Check the fixed public association before a links-enabled release.

    No account, cookies, password, provider key or arbitrary URL is accepted.
    The reviewed fixture pins the exact app and permitted/excluded routes.
    """
    services = validate_services(services)
    if services is None or not services["universal_links"]:
        return None
    if ASSOCIATION_FIXTURE.is_symlink() or not ASSOCIATION_FIXTURE.is_file():
        raise ValueError("Links require the reviewed CHIICH AASA fixture")
    if not 0 < ASSOCIATION_FIXTURE.stat().st_size <= ASSOCIATION_MAX_BYTES:
        raise ValueError("Links require a bounded reviewed CHIICH AASA fixture")
    expected = association_json(ASSOCIATION_FIXTURE.read_bytes())
    details = expected.get("applinks", {}).get("details", [])
    if (not isinstance(details, list) or len(details) != 1 or not isinstance(details[0], dict)
            or details[0].get("appIDs") != [TEAM + "." + APP]):
        raise ValueError("The reviewed AASA fixture must associate exactly the owned CHIICH app")
    request = Request(ASSOCIATION_URL, headers={"Accept": "application/json",
                                               "Accept-Encoding": "identity",
                                               "User-Agent": "CHIICH-association-check/1.0"})
    try:
        with build_opener(NoAssociationRedirects()).open(request, timeout=20) as response:
            if response.getcode() != 200 or response.geturl() != ASSOCIATION_URL:
                raise ValueError("AASA must respond HTTP 200 at the exact owned URL without a redirect")
            media_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            if media_type != "application/json":
                raise ValueError("AASA must be served as application/json before enabling Universal Links")
            payload = response.read(ASSOCIATION_MAX_BYTES + 1)
    except (OSError, URLError):
        raise ValueError("The owned AASA could not be read directly; redirects and retries are not allowed") from None
    # Canonical JSON preserves type distinctions such as false versus 0; Python
    # dictionary equality alone would accept that malformed association.
    published = json.dumps(association_json(payload), sort_keys=True, separators=(",", ":"))
    reviewed = json.dumps(expected, sort_keys=True, separators=(",", ":"))
    if published != reviewed:
        raise ValueError("Published AASA does not match the reviewed CHIICH app and route association")
    return {"url": ASSOCIATION_URL, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}


def replace_once(text, before, after, label):
    if text.count(before) != 1:
        raise ValueError(f"Unexpected {label}; source was not modified")
    return text.replace(before, after)


def run(args, label, *, data=None):
    # Do not expose command lines or subprocess output: some arguments are secrets.
    child_env = {key: value for key, value in os.environ.items()
                 if not key.startswith("CHIICH_IOS_") and key not in ASC_KEY_SECRETS}
    result = subprocess.run(args, input=data, capture_output=True, env=child_env)
    if result.returncode:
        raise ValueError(f"{label} failed (exit {result.returncode}); credentials were not logged")
    return result.stdout


def read_secret(name, *, encoded=False):
    value = os.environ.pop(name, "")
    if not value:
        raise ValueError(f"Required secret is missing: {name}")
    if not encoded:
        return value
    try:
        return base64.b64decode("".join(value.split()), validate=True)
    except ValueError:
        raise ValueError(f"{name} must contain base64 file bytes") from None


def write_private(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as handle:
        os.chmod(path, 0o600)
        handle.write(data)


def read_upload_key():
    # Remove both inputs before validation or invoking native tools. Never fall
    # back from a supplied but malformed raw key to a different credential.
    raw, encoded = (os.environ.pop(name, "") for name in ASC_KEY_SECRETS)
    name = ASC_KEY_SECRETS[0] if raw.strip() else ASC_KEY_SECRETS[1]
    value = raw if raw.strip() else encoded
    if not value.strip():
        raise ValueError("Required secret is missing: CHIICH_ASC_PRIVATE_KEY_P8 (or its BASE64 alternative)")
    try:
        if len(value) > 16384:
            raise ValueError()
        if name == ASC_KEY_SECRETS[1]:
            value = base64.b64decode("".join(value.split()), validate=True).decode("ascii")
        value = value.replace("\r\n", "\n").strip()
        match = re.fullmatch(r"-----BEGIN PRIVATE KEY-----\n([A-Za-z0-9+/=\n]+)\n-----END PRIVATE KEY-----", value)
        if not match:
            raise ValueError()
        payload = base64.b64decode(match[1].replace("\n", ""), validate=True)
        if not payload:
            raise ValueError()
        body = base64.b64encode(payload).decode("ascii")
        return ("-----BEGIN PRIVATE KEY-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
                + "\n-----END PRIVATE KEY-----\n").encode("ascii")
    except (ValueError, UnicodeError):
        raise ValueError(f"{name} must contain one unencrypted PKCS#8 PRIVATE KEY PEM file") from None


def validate_version(version, build):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Version must contain three numeric components, for example 0.1.0")
    if not re.fullmatch(r"[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}", build):
        raise ValueError("Build must match Apple CFBundleVersion limits (for example 1 or 2026.11.2)")


def validate_profile(profile, target, *, now=None, services=None):
    capabilities = required_capabilities(services)
    bundle = TARGETS[target][0]
    prefix = f"{TEAM}."
    ent = profile.get("Entitlements", {})
    if profile.get("TeamIdentifier") != [TEAM] or profile.get("ApplicationIdentifierPrefix") != [TEAM]:
        raise ValueError(f"{target}: provisioning profile belongs to a different Apple team/prefix")
    if ent.get("application-identifier") != prefix + bundle or ent.get("com.apple.developer.team-identifier") != TEAM:
        raise ValueError(f"{target}: provisioning profile does not match {bundle}")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime):
        raise ValueError(f"{target}: provisioning profile has no valid expiry")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    if expiry <= (now or datetime.now(timezone.utc)):
        raise ValueError(f"{target}: provisioning profile expired")
    if profile.get("ProvisionedDevices") is not None or profile.get("ProvisionsAllDevices") or ent.get("get-task-allow") is not False:
        raise ValueError(f"{target}: an App Store distribution profile is required")
    if ent.get("beta-reports-active") is not True:
        raise ValueError(f"{target}: profile is not enabled for TestFlight")
    if GROUP not in ent.get("com.apple.security.application-groups", []):
        raise ValueError(f"{target}: profile is missing app group {GROUP}")
    if not any(fnmatch.fnmatchcase(prefix + APP, item) for item in ent.get("keychain-access-groups", [])):
        raise ValueError(f"{target}: profile does not permit the shared CHIICH keychain")
    for key, value in capabilities[target].items():
        if key == ASSOCIATED_DOMAINS:
            # A profile is a permission allowlist. Apple can encode its wildcard
            # as the scalar "*" or an array entry. This does not change the
            # exact array required in the application's signed entitlements.
            allowed = ent.get(key)
            permitted = (allowed == "*"
                         or (isinstance(allowed, list)
                             and all(isinstance(item, str) for item in allowed)
                             and ("*" in allowed or all(item in allowed for item in value))))
        else:
            permitted = ent.get(key) == value
            if services is not None and isinstance(value, bool):
                permitted = ent.get(key) is value
        if not permitted:
            raise ValueError(f"{target}: profile is missing required entitlement {key}; obtain approval/configuration, do not strip it")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", uuid):
        raise ValueError(f"{target}: invalid profile UUID")
    certs = profile.get("DeveloperCertificates", [])
    if not certs or any(not isinstance(cert, bytes) for cert in certs):
        raise ValueError(f"{target}: profile contains no signing certificate")
    return {"uuid": uuid, "bundle_id": bundle, "certificate_sha1": {hashlib.sha1(cert).hexdigest().upper() for cert in certs}}


def prepare_source(source, version, build, profiles=None, identity=None, *, services=None):
    validate_version(version, build)
    services = validate_services(services)
    lock = json.loads((Path(__file__).parent / "upstream.lock.json").read_text())
    if json.loads((source / "CHIICH-SOURCE.json").read_text()) != lock:
        raise ValueError("Source must first be prepared with the current pinned CHIICH overlay")
    project = source / "project.yml"
    text = project.read_text()
    anchor = "# - path: MyAppVariant/override.yml"
    if text.count(anchor) != 1:
        raise ValueError("Unexpected XcodeGen include layout; source was not modified")
    main_target = (source / "ElementX/SupportingFiles/target.yml").read_text()
    settings_source = (source / "ElementX/Sources/Application/Settings/AppSettings.swift").read_text()
    account_source = (source / "ElementX/Sources/Application/Settings/AccountSettings.swift").read_text()
    if ("aps-environment:" in main_target
            or "com.apple.developer.associated-domains:" in main_target
            or settings_source.count(GATEWAY_DECLARATION) != 1
            or account_source.count(ACCOUNT_PREFERENCE) != 1
            or settings_source.count(ONBOARDING_PREFERENCE) != 1):
        raise ValueError("Signing must start from the prepared push-disabled trial source")
    nse_target = source / "NSE/SupportingFiles/target.yml"
    nse_text = nse_target.read_text()
    filtering_line = "        com.apple.developer.usernotifications.filtering: true\n"
    if nse_text.count(filtering_line) != 1:
        raise ValueError("Unexpected native NSE filtering configuration; source was not modified")
    for target in TARGETS:
        target_source = (source / target / "SupportingFiles/target.yml").read_text()
        if (SERVICES_INFO_KEY in target_source or "aps-environment:" in target_source
                or "com.apple.developer.associated-domains:" in target_source
                or (target != "NSE" and "com.apple.developer.usernotifications.filtering:" in target_source)):
            raise ValueError("Signing must start from the prepared push-disabled trial source without service metadata")
    updates = {}
    if services is not None:
        app_configuration = (source / "app.yml").read_text()
        for declaration in (f"  BASE_BUNDLE_IDENTIFIER: {APP}\n", f"  APP_GROUP_IDENTIFIER: {GROUP}\n"):
            if app_configuration.count(declaration) != 1:
                raise ValueError("Native services require the unchanged CHIICH application identifiers")
    if push_enabled(services):
        # The production branch remains the stock SDK pusher identity. Do not
        # replace it with a dev app ID or another service's registration.
        pusher = ('    var pusherAppID: String {\n        #if DEBUG\n'
                  '        InfoPlistReader.main.baseBundleIdentifier + ".ios.dev"\n'
                  '        #else\n        InfoPlistReader.main.baseBundleIdentifier + ".ios.prod"\n'
                  '        #endif\n    }')
        if settings_source.count(pusher) != 1:
            raise ValueError("Unexpected native production pusher identity; source was not modified")
        reader = (source / "ElementX/Sources/Other/InfoPlistReader.swift").read_text()
        onboarding = (source / "ElementX/Sources/FlowCoordinators/OnboardingFlowCoordinator.swift").read_text()
        if (reader.count("var chiichPushGatewayBaseURL: URL?") != 1
                or onboarding.count("!userSettings.app.hasRunNotificationPermissionsOnboarding && userSettings.account.enableNotifications") != 1):
            raise ValueError("Native services require the compiled service reader and opt-out-aware native onboarding")
        # The same native reader and preference expressions compile in both
        # modes. Only validated Info.plist metadata changes default values;
        # native preference stores retain explicit opt-outs and completed setup.
        entitlement_anchor = "        # APNs and universal links are configured only with CHIICH-owned signing and services.\n"
        entitlement_values = "        aps-environment: production\n"
        if services["universal_links"]:
            entitlement_values += "        com.apple.developer.associated-domains:\n        - applinks:chiich.one\n"
        main_target = replace_once(main_target, entitlement_anchor,
                                   entitlement_anchor + entitlement_values, "main-app service entitlements")
        info_anchor = "    info:\n      path: Info.plist\n      properties:\n"
        metadata = "        " + SERVICES_INFO_KEY + ": " + json.dumps(services, sort_keys=True) + "\n"
        for target in TARGETS:
            path = source / target / "SupportingFiles/target.yml"
            target_source = main_target if target == "ElementX" else path.read_text()
            if SERVICES_INFO_KEY in target_source:
                raise ValueError("Services metadata already exists; start from a freshly prepared checkout")
            updates[path] = replace_once(target_source, info_anchor, info_anchor + metadata,
                                         f"{target} Info.plist configuration")
    else:
        # This is an intentional trial policy, never a fallback after profile failure.
        updates[nse_target] = nse_text.replace(filtering_line, "")
        if services is not None:
            entitlement_anchor = "        # APNs and universal links are configured only with CHIICH-owned signing and services.\n"
            entitlement_values = "        com.apple.developer.associated-domains:\n        - applinks:chiich.one\n"
            updates[source / "ElementX/SupportingFiles/target.yml"] = replace_once(
                main_target, entitlement_anchor, entitlement_anchor + entitlement_values,
                "links-only main-app entitlement")
    # Root project settings override included project settings. Set versions at
    # target level, above those inherited defaults and the upstream self-references.
    config = {"targets": {target: {"settings": {"base": {
        "MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": build,
    }}} for target in TARGETS}}
    if profiles is not None:
        config["settings"] = {"DEVELOPMENT_TEAM": TEAM}
        for target, info in profiles.items():
            config["targets"][target]["settings"]["base"].update({
                "DEVELOPMENT_TEAM": TEAM,
                "CODE_SIGN_STYLE": "Manual",
                "CODE_SIGN_IDENTITY": identity,
                "PROVISIONING_PROFILE_SPECIFIER": info["uuid"],
            })
    (source / "chiich-signing.yml").write_text(json.dumps(config, indent=2) + "\n")
    project.write_text(text.replace(anchor, "- path: chiich-signing.yml"))
    for path, updated_source in updates.items():
        path.write_text(updated_source)


def state_path():
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    return root / "chiich-ios-signing"


def install(source, version, build, *, services=None):
    services = validate_services(services)
    verify_live_association(services)
    state = state_path()
    state.mkdir(mode=0o700, exist_ok=False)
    os.chmod(state, 0o700)
    # Record only non-secret paths before making system changes, for always() cleanup.
    previous = shlex.split(run(["security", "list-keychains", "-d", "user"], "Read keychain search list").decode())
    keychain = state / "build.keychain-db"
    manifest = {"previous_keychains": previous, "profiles": [], "keychain": str(keychain)}
    manifest_file = state / "cleanup.json"
    manifest_file.write_text(json.dumps(manifest))
    parsed = {}
    payloads = {}
    for target, (_, secret_name) in TARGETS.items():
        raw = read_secret(secret_name, encoded=True)
        path = state / f"{target}.mobileprovision"
        write_private(path, raw)
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)], f"Decode {target} provisioning profile"))
        parsed[target] = validate_profile(profile, target, services=services)
        payloads[target] = raw
    if len({item["uuid"] for item in parsed.values()}) != len(TARGETS):
        raise ValueError("Each target needs a distinct provisioning profile")
    p12 = state / "distribution.p12"
    write_private(p12, read_secret("CHIICH_IOS_DISTRIBUTION_P12_BASE64", encoded=True))
    p12_password = read_secret("CHIICH_IOS_DISTRIBUTION_P12_PASSWORD")
    keychain_password = secrets.token_urlsafe(48)
    run(["security", "create-keychain", "-p", keychain_password, str(keychain)], "Create temporary signing keychain")
    run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)], "Set temporary keychain timeout")
    run(["security", "unlock-keychain", "-p", keychain_password, str(keychain)], "Unlock temporary signing keychain")
    run(["security", "import", str(p12), "-P", p12_password, "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], "Import distribution certificate")
    p12.unlink()
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-k", keychain_password, str(keychain)], "Enable native signing tools")
    identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], "Find valid distribution identity").decode()
    available = set(re.findall(r'\b([A-Fa-f0-9]{40})\s+"(?:Apple Distribution|iPhone Distribution):', identities))
    available = {item.upper() for item in available}
    for info in parsed.values():
        available &= info["certificate_sha1"]
    if len(available) != 1:
        raise ValueError("Exactly one valid imported distribution identity must match all three profiles")
    identity = available.pop()
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    for target, info in parsed.items():
        path = PROFILE_DIR / f"{info['uuid']}.mobileprovision"
        if path.exists():
            raise ValueError("Profile installation would overwrite a pre-existing profile")
        manifest["profiles"].append(str(path))
        manifest_file.write_text(json.dumps(manifest))
        write_private(path, payloads[target])
    run(["security", "list-keychains", "-d", "user", "-s", *previous, str(keychain)], "Add temporary keychain to search path")
    prepare_source(source, version, build, parsed, identity, services=services)
    options = {
        "method": "app-store-connect", "destination": "export", "teamID": TEAM,
        "signingStyle": "manual", "signingCertificate": identity,
        "provisioningProfiles": {info["bundle_id"]: info["uuid"] for info in parsed.values()},
        "manageAppVersionAndBuildNumber": False, "uploadSymbols": True, "stripSwiftSymbols": True,
    }
    (state / "ExportOptions.plist").write_bytes(plistlib.dumps(options))
    print("Validated CHIICH distribution certificate, three profiles and retained entitlements")


def verify_app(app, version=None, build=None, *, signed=True, services=None):
    services = validate_services(services)
    capabilities = required_capabilities(services)
    paths = {"ElementX": app, "NSE": app / "PlugIns/NSE.appex", "ShareExtension": app / "PlugIns/ShareExtension.appex"}
    for target, path in paths.items():
        if signed:
            run(["codesign", "--verify", "--strict", str(path)], f"Verify {target} code signature")
        with (path / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
            if info.get("CFBundleIdentifier") != TARGETS[target][0]:
                raise ValueError(f"{target}: unexpected signed bundle identifier")
            if version is not None and info.get("CFBundleShortVersionString") != version:
                raise ValueError(f"{target}: unexpected release version")
            if build is not None and info.get("CFBundleVersion") != build:
                raise ValueError(f"{target}: unexpected build number")
            if not push_enabled(services):
                if SERVICES_INFO_KEY in info:
                    raise ValueError(f"{target}: services metadata violates the explicit push-disabled trial policy")
            else:
                if validate_services(info.get(SERVICES_INFO_KEY)) != services:
                    raise ValueError(f"{target}: services metadata does not match the reviewed configuration")
            if services is not None:
                expected_identity = {"baseBundleIdentifier": APP, "appGroupIdentifier": GROUP,
                                     "keychainAccessGroupIdentifier": (TEAM if signed else "") + "." + APP}
                if any(info.get(key) != value for key, value in expected_identity.items()):
                    raise ValueError(f"{target}: native services use unexpected shared application identifiers")
        if not signed:
            continue
        if services is not None:
            embedded_profile = plistlib.loads(run(
                ["security", "cms", "-D", "-i", str(path / "embedded.mobileprovision")],
                f"Decode {target} embedded distribution profile"))
            validate_profile(embedded_profile, target, services=services)
        ent = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(path)], f"Read {target} signed entitlements"))
        for key in SERVICE_ENTITLEMENTS:
            if key in ent and key not in capabilities[target]:
                policy = "push-disabled trial policy" if services is None else "reviewed per-target services policy"
                raise ValueError(f"{target}: signed output violates the explicit {policy}")
        if ent.get("com.apple.developer.team-identifier") != TEAM or ent.get("application-identifier") != TEAM + "." + TARGETS[target][0]:
            raise ValueError(f"{target}: incorrect signed team/application identity")
        if ent.get("get-task-allow") is True or GROUP not in ent.get("com.apple.security.application-groups", []):
            raise ValueError(f"{target}: invalid distribution/app-group entitlements")
        if TEAM + "." + APP not in ent.get("keychain-access-groups", []):
            raise ValueError(f"{target}: shared keychain entitlement is missing")
        for key, value in capabilities[target].items():
            if ent.get(key) != value or (services is not None and isinstance(value, bool) and ent.get(key) is not value):
                raise ValueError(f"{target}: signed app lost required entitlement {key}")
    print("Verified app and both extensions" + ("; native signed CHIICH entitlements retained" if signed else "; unsigned archive identity/version only"))


def verify_ipa(ipa, version, build, *, services=None):
    services = validate_services(services)
    # The input is our own export/same-run artifact, but still reject traversal.
    with zipfile.ZipFile(ipa) as bundle:
        for name in bundle.namelist():
            path = Path(name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Package contains an unsafe archive member")
    with tempfile.TemporaryDirectory(prefix="chiich-package-", dir=os.environ["RUNNER_TEMP"]) as temp:
        run(["ditto", "-x", "-k", str(ipa.resolve()), temp], "Extract signed package")
        apps = list((Path(temp) / "Payload").glob("*.app"))
        if len(apps) != 1 or apps[0].name != "ElementX.app":
            raise ValueError("Export does not contain exactly the CHIICH application")
        verify_app(apps[0], version, build, services=services)


def package(export_dir, output, version, build, source_sha, *, services=None):
    validate_version(version, build)
    services = validate_services(services)
    if not re.fullmatch(r"[a-f0-9]{40}", source_sha):
        raise ValueError("A full source commit is required")
    ipas = list(export_dir.glob("*.ipa"))
    if len(ipas) != 1:
        raise ValueError("Export must contain exactly one IPA")
    verify_ipa(ipas[0], version, build, services=services)
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(ipas[0], output / "CHIICH.ipa")
    receipt = {"source_sha": source_sha, "version": version, "build": build,
               "app_id": "6829606447", "bundle_id": APP, "team_id": TEAM,
               **service_provenance(services),
               "ipa_sha256": hashlib.sha256(ipas[0].read_bytes()).hexdigest()}
    (output / "provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Prepared one verified IPA and non-secret source provenance")


def verify_package(directory, version, build, source_sha, *, services=None):
    validate_version(version, build)
    services = validate_services(services)
    if not re.fullmatch(r"[a-f0-9]{40}", source_sha):
        raise ValueError("A full source commit is required")
    receipt = json.loads((directory / "provenance.json").read_text())
    if services is not None:
        validate_services(receipt.get("native_services"))
    expected = {"source_sha": source_sha, "version": version, "build": build,
                "app_id": "6829606447", "bundle_id": APP, "team_id": TEAM,
                **service_provenance(services)}
    if (set(receipt) != set(expected) | {"ipa_sha256"}
            or any(receipt.get(key) != value for key, value in expected.items())):
        raise ValueError("Downloaded package does not match the reviewed CHIICH source/version")
    ipa = directory / "CHIICH.ipa"
    if hashlib.sha256(ipa.read_bytes()).hexdigest() != receipt.get("ipa_sha256"):
        raise ValueError("Downloaded package digest does not match the signing job")
    verify_live_association(services)
    verify_ipa(ipa, version, build, services=services)


def upload(ipa, version, build, app_id, key_id, issuer_id):
    validate_version(version, build)
    if app_id != "6829606447" or not re.fullmatch(r"[A-Za-z0-9]{10}", key_id) or not re.fullmatch(r"[A-Fa-f0-9-]{36}", issuer_id):
        raise ValueError("Invalid CHIICH App Store Connect app/key/issuer configuration")
    key_dir = state_path() / "private_keys"
    key = key_dir / f"AuthKey_{key_id}.p8"
    write_private(key, read_upload_key())
    os.environ["API_PRIVATE_KEYS_DIR"] = str(key_dir)
    try:
        # Validation has no distribution side effect; upload is one attempt, never retried.
        run(["xcrun", "altool", "--validate-app", "-f", str(ipa), "-t", "ios", "--apiKey", key_id, "--apiIssuer", issuer_id], "Apple package validation")
        run(["xcrun", "altool", "--upload-package", str(ipa), "-t", "ios", "--apple-id", app_id,
             "--bundle-id", APP, "--bundle-short-version-string", version, "--bundle-version", build,
             "--apiKey", key_id, "--apiIssuer", issuer_id, "--output-format", "json"],
            "Apple upload (if uncertain, inspect this version/build in App Store Connect before any retry)")
        print("Apple accepted the upload request; processing/TestFlight availability is not yet confirmed")
    finally:
        key.unlink(missing_ok=True)


def cleanup():
    state = state_path()
    manifest_file = state / "cleanup.json"
    failures = []
    if manifest_file.exists():
        data = json.loads(manifest_file.read_text())
        try:
            run(["security", "list-keychains", "-d", "user", "-s", *data["previous_keychains"]], "Restore keychain search list")
        except (ValueError, OSError):
            failures.append("restore keychain search list")
        keychain = state / "build.keychain-db"
        if keychain.exists():
            try:
                run(["security", "delete-keychain", str(keychain)], "Delete temporary keychain")
            except (ValueError, OSError):
                failures.append("delete temporary keychain")
        for name in data["profiles"]:
            path = Path(name)
            if path.parent != PROFILE_DIR or not re.fullmatch(r"[A-Fa-f0-9-]{36}\.mobileprovision", path.name):
                failures.append("unexpected profile cleanup path")
                continue
            try:
                path.unlink(missing_ok=True)
            except OSError:
                failures.append("remove installed provisioning profile")
    if state.exists():
        shutil.rmtree(state)
    if failures:
        raise ValueError("Cleanup incomplete: " + ", ".join(failures))
    print("Temporary signing material removed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    service_commands = []
    service_commands.append(sub.add_parser("check-services", help="Validate the selected services mode before loading credentials"))
    for command in ("unsigned", "install"):
        p = sub.add_parser(command)
        service_commands.append(p)
        p.add_argument("--source", type=Path, required=True)
        p.add_argument("--version", required=True)
        p.add_argument("--build", required=True)
    p = sub.add_parser("verify")
    service_commands.append(p)
    p.add_argument("--archive", type=Path, required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--unsigned", action="store_true")
    for command in ("package", "verify-package"):
        p = sub.add_parser(command)
        service_commands.append(p)
        if command == "package":
            p.add_argument("--export-dir", type=Path, required=True)
            p.add_argument("--output", type=Path, required=True)
        else:
            p.add_argument("--directory", type=Path, required=True)
        p.add_argument("--version", required=True)
        p.add_argument("--build", required=True)
        p.add_argument("--source-sha", required=True)
    for p in service_commands:
        p.add_argument("--service-mode", choices=(TRIAL, LINKS_ONLY, SERVICES_ENABLED), default=TRIAL)
        p.add_argument("--services-config", type=Path,
                       help="Only the reviewed src/element-x-ios/services.json is accepted in services-enabled mode")
    p = sub.add_parser("upload")
    p.add_argument("--ipa", type=Path, required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--app-id", required=True)
    p.add_argument("--key-id", required=True)
    p.add_argument("--issuer-id", required=True)
    sub.add_parser("cleanup")
    args = parser.parse_args()
    services = load_services(args.service_mode, args.services_config) if hasattr(args, "service_mode") else None
    if args.command == "check-services":
        association = verify_live_association(services)
        print("Validated native services mode: " + args.service_mode + "; no provider request or credential access")
        if association is not None:
            print("Verified public CHIICH AASA: " + association["sha256"])
    elif args.command == "unsigned":
        prepare_source(args.source, args.version, args.build, services=services)
    elif args.command == "install":
        install(args.source, args.version, args.build, services=services)
    elif args.command == "verify":
        verify_app(args.archive / "Products/Applications/ElementX.app", args.version, args.build,
                   signed=not args.unsigned, services=services)
    elif args.command == "package":
        package(args.export_dir, args.output, args.version, args.build, args.source_sha, services=services)
    elif args.command == "verify-package":
        verify_package(args.directory, args.version, args.build, args.source_sha, services=services)
    elif args.command == "upload":
        upload(args.ipa, args.version, args.build, args.app_id, args.key_id, args.issuer_id)
    else:
        cleanup()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        # Our validation messages contain field names, never raw secret values.
        print(f"CHIICH signing: {error}", file=sys.stderr)
        sys.exit(1)
