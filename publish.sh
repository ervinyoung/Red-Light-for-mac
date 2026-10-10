#!/bin/zsh
# One-shot publish: creates the public repo, pushes, turns on GitHub Pages from /docs, and releases this version
# with ./release.sh --publish (the disk image, the update zip and its signature) unless it is already out.
# Run once after `gh auth login`.
set -e
cd "$(dirname "$0")"
TAG="v$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Info.plist)"
# Check before anything is pushed: a release that can't be signed would fail only at the last step, after the repo
# went public. (Without -w, find-generic-password only looks the key up; it doesn't read it.)
gh release view "$TAG" >/dev/null 2>&1 || security find-generic-password -s "Red Light update signing key" -a redlight >/dev/null 2>&1 \
  || { echo "no update signing key in the login Keychain; release.sh needs it to sign $TAG"; exit 1; }
LOGIN=$(gh api user --jq .login)
echo "→ publishing as $LOGIN"
if [ "$LOGIN" != "ervinyoung" ]; then
  # the page and README were written for ervinyoung; point them at the real account
  sed -i '' "s#ervinyoung.github.io#$LOGIN.github.io#g; s#github.com/ervinyoung#github.com/$LOGIN#g" docs/index.html README.md
  git add -A && git commit -q -m "Point links at $LOGIN" || true
  echo "note: the app's updater (Updater.feed and publicKey in app/RedLightApp.swift) still follows ervinyoung's releases"
fi
if ! gh repo view "$LOGIN/Red-Light-for-mac" >/dev/null 2>&1; then
  gh repo create "$LOGIN/Red-Light-for-mac" --public --description "Warm light after dark, for Mac. Zero blue at 60%, a keyboard dimmer than the slider allows, and it learns your nights." --homepage "https://$LOGIN.github.io/Red-Light-for-mac/" --source . --remote origin --push
else
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$LOGIN/Red-Light-for-mac.git"
  git push -u origin main
fi
echo "→ enabling GitHub Pages from /docs"
gh api -X POST "repos/$LOGIN/Red-Light-for-mac/pages" -f 'source[branch]=main' -f 'source[path]=/docs' >/dev/null 2>&1 \
  || gh api -X PUT "repos/$LOGIN/Red-Light-for-mac/pages" -f 'source[branch]=main' -f 'source[path]=/docs' >/dev/null
gh repo edit "$LOGIN/Red-Light-for-mac" --add-topic macos --add-topic blue-light --add-topic sleep --add-topic menu-bar --add-topic swift >/dev/null 2>&1 || true
echo "→ release"
if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG is already released"; else ./release.sh --publish; fi
echo
echo "Site:    https://$LOGIN.github.io/Red-Light-for-mac/   (Pages takes a minute or two on first publish)"
echo "Repo:    https://github.com/$LOGIN/Red-Light-for-mac"
