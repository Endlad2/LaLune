[app]

title = LaLune
package.name = lalune
package.domain = org.lalune

source.dir = .
source.include_exts = py,png,jpg,kv,atlas,html,js,css
source.include_patterns = Frontend/*,Mobile/*

version = 0.4.0

requirements = python3,kivy==2.2.0,kivy-garden.xwebview

garden_requirements = xwebview

orientation = portrait
fullscreen = 0

android.permissions = INTERNET,ACCESS_NETWORK_STATE
android.api = 31
android.minapi = 21
android.gradle_dependencies = 'androidx.webkit:webkit:1.4.0'

# iOS
# ios.bundle_identifier = org.lalune
# ios.bundle_name = LaLune
