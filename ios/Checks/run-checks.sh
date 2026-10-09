#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CHECK_BUILD_DIR="${FONOO_CHECK_BUILD_DIR:-build/checks}"
mkdir -p "$CHECK_BUILD_DIR/module-cache"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/SIPAccount.swift Fonoo/SIPCore.swift Fonoo/Diagnostics.swift \
  Fonoo/SIPConnectionCoordinator.swift Checks/SIPConnectionChecks.swift -o "$CHECK_BUILD_DIR/SIPConnectionChecks"
"$CHECK_BUILD_DIR/SIPConnectionChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/SIPAccount.swift Fonoo/SIPCore.swift Fonoo/Diagnostics.swift \
  Fonoo/IncomingCallCoordinator.swift Fonoo/CallManager.swift Checks/CallFlowChecks.swift -o "$CHECK_BUILD_DIR/CallFlowChecks"
"$CHECK_BUILD_DIR/CallFlowChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/DeviceContact.swift Checks/ContactSearchChecks.swift \
  -o "$CHECK_BUILD_DIR/ContactSearchChecks"
"$CHECK_BUILD_DIR/ContactSearchChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/SIPAccount.swift Checks/NATChecks.swift -o "$CHECK_BUILD_DIR/NATChecks"
"$CHECK_BUILD_DIR/NATChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/SIPAccount.swift Fonoo/SIPCore.swift Fonoo/Diagnostics.swift \
  Fonoo/IncomingCallCoordinator.swift Checks/IncomingCallChecks.swift -o "$CHECK_BUILD_DIR/IncomingCallChecks"
"$CHECK_BUILD_DIR/IncomingCallChecks"
plutil -lint Fonoo.xcodeproj/project.pbxproj

swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Checks/CallHistoryChecks.swift -o "$CHECK_BUILD_DIR/CallHistoryChecks"
"$CHECK_BUILD_DIR/CallHistoryChecks"

swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Checks/CloudHistoryChecks.swift -o "$CHECK_BUILD_DIR/CloudHistoryChecks"
"$CHECK_BUILD_DIR/CloudHistoryChecks"
python3 Checks/cloud-history-sync-checks.py

swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/SIPAccount.swift Fonoo/SystemCallActivity.swift \
  Checks/SystemCallActivityChecks.swift -o "$CHECK_BUILD_DIR/SystemCallActivityChecks"
"$CHECK_BUILD_DIR/SystemCallActivityChecks"

# Both apps compile these same models and presentation state.
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/TeamMember.swift Fonoo/TeamDirectory.swift \
  Checks/TeamDirectoryChecks.swift -o "$CHECK_BUILD_DIR/TeamDirectoryChecks"
"$CHECK_BUILD_DIR/TeamDirectoryChecks"
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/TeamMember.swift Checks/DeviceProfileChecks.swift \
  -o "$CHECK_BUILD_DIR/DeviceProfileChecks"
"$CHECK_BUILD_DIR/DeviceProfileChecks"
python3 Checks/siri-vocabulary-checks.py
swiftc -parse-as-library -module-cache-path "$CHECK_BUILD_DIR/module-cache" \
  Fonoo/CallSession.swift Fonoo/TeamMember.swift Fonoo/DeviceContact.swift Checks/TeamPresenceChecks.swift \
  -o "$CHECK_BUILD_DIR/TeamPresenceChecks"
"$CHECK_BUILD_DIR/TeamPresenceChecks"
