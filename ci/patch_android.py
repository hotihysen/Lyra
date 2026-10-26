"""Ergänzt das von `flutter create` erzeugte Android-Gerüst um die Extraktor-Bibliotheken."""
import os, re, sys

root = "android"
top = os.path.join(root, "build.gradle.kts")
app = os.path.join(root, "app", "build.gradle.kts")
if not (os.path.exists(top) and os.path.exists(app)):
    sys.exit("Erwartete Kotlin-Gradle-Dateien fehlen")

s = open(top).read()
if "jitpack.io" not in s:
    s = s.replace(
        "mavenCentral()",
        'mavenCentral()\n        maven { url = uri("https://jitpack.io") }\n'
        '        maven { url = uri("https://raw.githubusercontent.com/bravepipeproject/maven-repo/master/repository") }',
        1,
    )
open(top, "w").write(s)

a = open(app).read()
a = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk = 26", a, count=1)
# Fester Signaturschlüssel ausdrücklich setzen. Vorher verliess sich der Build auf
# ~/.android/debug.keystore; tatsächlich wurde bei jedem Lauf ein neuer Schlüssel erzeugt,
# und jede Version hatte ein anderes Zertifikat (Updates unmöglich).
if 'create("lyra")' not in a:
    a = a.replace("    buildTypes {", '''    signingConfigs {
        create("lyra") {
            storeFile = rootProject.file("../ci/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {''', 1)
if 'signingConfigs.getByName("debug")' not in a:
    sys.exit("Release-Signierung im Gradle-Gerüst nicht gefunden")
# Keine Code-Verkleinerung: die Extraktoren nutzen Reflection und R8 bricht sonst ab
a = a.replace('signingConfig = signingConfigs.getByName("debug")',
              'signingConfig = signingConfigs.getByName("lyra")\n            isMinifyEnabled = false\n            isShrinkResources = false', 1)
if 'create("lyra")' not in a:
    sys.exit("Signatur-Konfiguration konnte nicht eingefügt werden")
if "isCoreLibraryDesugaringEnabled" not in a:
    a = a.replace("compileOptions {", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
a += """
// Wie SimpMusic: PipePipe bringt protobuf-java, BravePipe protobuf-javalite; nur javalite behalten.
// Und nanojson auf den Stand zwingen, den beide Extraktoren erwarten.
configurations.all {
    exclude(group = "com.google.protobuf", module = "protobuf-java")
    resolutionStrategy {
        force("com.github.TeamNewPipe:nanojson:c7a6c1c08d16b6d5ecded34758e6415e07be2166")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.github.maxrave-dev:PipePipeExtractor:f8982ca9e7")
    implementation("com.github.maxrave-dev:BravePipeExtractor:0fcaf19ecc")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
"""
open(app, "w").write(a)
print(open(top).read())
print(open(app).read())
