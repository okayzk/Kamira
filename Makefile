.PHONY: build run test check universal package release release-dry-run icon clean

# Development build for this Mac, at build/<NAME>.app (NAME and BUNDLE_ID are in app.env).
build:
	@./scripts/build.sh

# Build, then replace the running copy with the new one. Quitting through the app
# (rather than killing it) lets it move unsaved recordings to the screenshot folder.
run: build
	@. ./app.env; osascript -e "tell application id \"$$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true; \
	  sleep 1; open "build/$$NAME.app"

# Unit tests only.
test:
	@./scripts/test.sh

# Everything that must pass before a commit: tests, the folders' boundaries, both text tables, the app's name
# against app.env, release notes, the incident ledger, and what the change's paths ask
# for on top.
check: test
	@./scripts/check_structure.sh
	@python3 scripts/check_localization.py
	@python3 scripts/check_identity.py
	@./scripts/check_release_notes.sh
	@python3 scripts/check_incidents.py
	@python3 scripts/risk_tier.py

# What a release ships, without publishing anything: dist/<NAME>.{app,dmg,zip}.
package:
	@./scripts/package.sh

release-dry-run:
	@./scripts/release.sh --dry-run

release:
	@./scripts/release.sh

# Redraw the app icon and the README logo from Sources/App/AppMark.swift.
icon:
	@./scripts/make_icon.sh

clean:
	rm -rf build dist
