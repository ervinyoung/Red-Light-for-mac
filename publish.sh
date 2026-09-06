#!/bin/zsh
# One-shot publish: creates the public repo, pushes, turns on GitHub Pages from /docs, uploads the release.
# Run once after `gh auth login`.
set -e
cd "$(dirname "$0")"
LOGIN=$(gh api user --jq .login)
echo "→ publishing as $LOGIN"
if [ "$LOGIN" != "ervinyoung" ]; then
  # the page and README were written for ervinyoung; point them at the real account
  sed -i '' "s#ervinyoung.github.io#$LOGIN.github.io#g; s#github.com/ervinyoung#github.com/$LOGIN#g" docs/index.html README.md
  git add -A && git commit -q -m "Point links at $LOGIN" || true
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
ZIP="../RedLight-2.2-macos26-arm64.zip"
gh release view v2.2 >/dev/null 2>&1 || gh release create v2.2 "$ZIP" --title "Red Light 2.2" --notes "Prebuilt Red Light.app and the redlight engine for Apple silicon, macOS 26+. Ad-hoc signed: right-click › Open the first time. Building from source with ./install.sh is recommended."
echo
echo "Site:    https://$LOGIN.github.io/redlight/   (Pages takes a minute or two on first publish)"
echo "Repo:    https://github.com/$LOGIN/Red-Light-for-mac"
