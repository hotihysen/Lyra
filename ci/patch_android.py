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
if "isCoreLibraryDesugaringEnabled" not in a:
    a = a.replace("compileOptions {", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
a += """
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
