#!/bin/bash

set -e

# Генерация Xcode проекта из project.yml
if command -v xcodegen &> /dev/null; then
    echo "Generating Xcode project..."
    xcodegen generate
else
    echo "xcodegen not found, installing..."
    brew install xcodegen
    xcodegen generate
fi

# Сборка
echo "Building..."
xcodebuild \
    -project LaLune.xcodeproj \
    -scheme LaLune \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath build/LaLune.xcarchive \
    archive

# Экспорт IPA
echo "Exporting IPA..."
xcodebuild \
    -exportArchive \
    -archivePath build/LaLune.xcarchive \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath build/

echo "Done! IPA at build/LaLune.ipa"
