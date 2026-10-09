#!/usr/bin/env python3
"""Read-only inspection of a built app. Does not validate signatures or send a push."""
import argparse
import json
import plistlib
from pathlib import Path


def inspect_bundle(bundle):
    info_path = bundle / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    result = {'bundle_id': info.get('CFBundleIdentifier'),
              'background_modes': info.get('UIBackgroundModes', [])}
    profile_path = bundle / 'embedded.mobileprovision'
    if profile_path.exists():
        # Inspect only the embedded plist; signature verification is explicitly not asserted.
        raw = profile_path.read_bytes()
        start = raw.find(b'<?xml')
        end = raw.find(b'</plist>', start)
        if start < 0 or end < 0:
            raise ValueError('No readable provisioning plist')
        profile = plistlib.loads(raw[start:end + len(b'</plist>')])
        result.update(local_provision=profile.get('LocalProvision', False),
                      profile_push_environment=profile.get('Entitlements', {}).get('aps-environment'),
                      profile_expires=str(profile.get('ExpirationDate', 'unknown')))
    else:
        result.update(local_provision=None, profile_push_environment=None)
    blockers = []
    if result['local_provision']:
        blockers.append('Lokales Entwicklungsprofil: Push-faehiges Team/Profil erforderlich.')
    if not result['profile_push_environment']:
        blockers.append('Profil enthaelt keine aps-environment-Berechtigung.')
    for mode in ('voip', 'audio'):
        if mode not in result['background_modes']:
            blockers.append('Background Mode fehlt: ' + mode)
    result['local_setup_blockers'] = blockers
    result['live_push_test'] = 'Nicht geprueft; Profil und Background Modes beweisen keine Erreichbarkeit.'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect_bundle(args.app), ensure_ascii=False, indent=2))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(2, 'App/Profil nicht lesbar: ' + str(error) + '\n')
