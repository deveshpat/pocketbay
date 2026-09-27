#!/bin/zsh
# Publishes a new Windows release that every installed copy picks up automatically.
# Usage: scripts/release-windows.sh 1.0.1 "What changed"
set -euo pipefail
VERSION=${1:?usage: release-windows.sh <version> "<notes>"}
NOTES=${2:-"Bug fixes and improvements"}
ROOT="${0:A:h:h}"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
cd "$ROOT/windows"

sed -i '' -E "s|<Version>[^<]*</Version>|<Version>$VERSION</Version>|" Pocketbay.csproj
"$DOTNET" publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o publish
rm -f publish/*.pdb Pocketbay-Windows.zip
(cd publish && zip -q -9 ../Pocketbay-Windows.zip Pocketbay.exe READ-ME-FIRST.txt)

cd "$ROOT"
git add -A && git commit -qm "Release Windows $VERSION" || true
git push -q
gh release create "v$VERSION" windows/Pocketbay-Windows.zip --title "Pocketbay $VERSION" --notes "$NOTES"
echo "Released v$VERSION — installed copies update on their next launch."
