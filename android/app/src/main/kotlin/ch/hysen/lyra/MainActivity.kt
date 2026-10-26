package ch.hysen.lyra

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val worker = Executors.newFixedThreadPool(3)
    private var updateChannel: MethodChannel? = null

    companion object {
        @Volatile var current: WeakReference<MainActivity>? = null
        private const val REQUEST_INSTALL = 4711
        private const val FILE_PROVIDER_SUFFIX = ".updates"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
    }

    override fun onResume() {
        super.onResume()
        current = WeakReference(this)
    }

    override fun onDestroy() {
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    /** Sendet ein Ereignis an den Dart-Teil (immer auf dem UI-Thread). */
    fun sendUpdateEvent(method: String, args: Map<String, Any?>) {
        runOnUiThread { updateChannel?.invokeMethod(method, args) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.hysen.lyra/extract")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "audio" -> {
                        val id = call.argument<String>("id") ?: ""
                        worker.execute {
                            try {
                                val a = Extractor.audio(id)
                                runOnUiThread {
                                    result.success(mapOf("url" to a.url, "itag" to a.itag, "source" to a.source, "ua" to Extractor.USER_AGENT))
                                }
                            } catch (t: Throwable) {
                                runOnUiThread { result.error("extract", t.message ?: t.javaClass.simpleName, null) }
                            }
                        }
                    }
                    "lastCrash" -> result.success(LyraApp.takeCrash(application))
                    else -> result.notImplemented()
                }
            }

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.hysen.lyra/update")
        updateChannel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "canInstall" -> result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) packageManager.canRequestPackageInstalls() else true
                    )
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        }
                        result.success(true)
                    }
                    "inspectApk" -> {
                        val path = call.argument<String>("path")!!
                        worker.execute {
                            try {
                                val info = inspectApk(File(path))
                                runOnUiThread { result.success(info) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("inspect", e.message ?: e.javaClass.simpleName, null) }
                            }
                        }
                    }
                    "openInstaller" -> {
                        openInstaller(File(call.argument<String>("path")!!))
                        result.success(true)
                    }
                    "installSession" -> {
                        val file = File(call.argument<String>("path")!!)
                        UpdateStatus.reset()
                        worker.execute {
                            try {
                                val id = installWithSession(file)
                                runOnUiThread { result.success(id) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("session", e.message ?: e.javaClass.simpleName, null) }
                            }
                        }
                    }
                    "abandonSession" -> {
                        val id = UpdateStatus.sessionId
                        if (id != null) {
                            try {
                                packageManager.packageInstaller.abandonSession(id)
                            } catch (_: Exception) {
                            }
                            UpdateStatus.sessionId = null
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("update", e.message, null)
            }
        }
    }

    // ---------- Klassischer Installer (Standard, wie Flimmer) ----------

    /**
     * Öffnet Androids Installationsdialog mit einer content://-URI aus dem FileProvider.
     * Mit startActivityForResult meldet Android zurück, ob abgebrochen oder abgelehnt wurde.
     * Kein FLAG_ACTIVITY_NEW_TASK: sonst käme sofort «abgebrochen» zurück.
     */
    private fun openInstaller(file: File) {
        val uri = FileProvider.getUriForFile(this, packageName + FILE_PROVIDER_SUFFIX, file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
            .putExtra(Intent.EXTRA_RETURN_RESULT, true)
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_INSTALL)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL) {
            val installResult = data?.extras?.let {
                if (it.containsKey("android.intent.extra.INSTALL_RESULT")) it.getInt("android.intent.extra.INSTALL_RESULT") else null
            }
            sendUpdateEvent("installerResult", mapOf("resultCode" to resultCode, "installResult" to installResult))
        }
    }

    // ---------- APK vor der Installation prüfen ----------

    private fun inspectApk(file: File): Map<String, Any?> {
        @Suppress("DEPRECATION")
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES
        @Suppress("DEPRECATION")
        val archive = packageManager.getPackageArchiveInfo(file.path, flags)
            ?: throw IllegalStateException("Die Datei ist keine gültige APK")
        archive.applicationInfo?.let {
            it.sourceDir = file.path
            it.publicSourceDir = file.path
        }
        val installed: PackageInfo? = try {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, flags)
        } catch (_: Exception) {
            null
        }
        val a = certHashes(archive)
        val i = certHashes(installed)
        val same: Boolean? = if (a.isEmpty() || i.isEmpty()) null else a.intersect(i).isNotEmpty()
        return mapOf(
            "packageName" to archive.packageName,
            "versionName" to archive.versionName,
            "versionCode" to versionCode(archive),
            "installedVersionCode" to (installed?.let { versionCode(it) } ?: -1L),
            "installedVersionName" to installed?.versionName,
            "sameSignature" to same,
        )
    }

    @Suppress("DEPRECATION")
    private fun versionCode(p: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) p.longVersionCode else p.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun certHashes(p: PackageInfo?): Set<String> {
        if (p == null) return emptySet()
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val si = p.signingInfo ?: return emptySet()
            if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
        } else {
            p.signatures
        } ?: return emptySet()
        val md = MessageDigest.getInstance("SHA-256")
        return sigs.map { s -> md.digest(s.toByteArray()).joinToString("") { "%02x".format(it) } }.toSet()
    }

    // ---------- PackageInstaller-Sitzung (nur Diagnose) ----------

    private fun installWithSession(file: File): Int {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        params.setSize(file.length())
        val id = installer.createSession(params)
        UpdateStatus.sessionId = id
        try {
            installer.openSession(id).use { session ->
                session.openWrite("lyra-update", 0, file.length()).use { out ->
                    file.inputStream().use { it.copyTo(out, 1 shl 16) }
                    session.fsync(out)
                }
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pi = PendingIntent.getBroadcast(this, id, Intent(this, UpdateReceiver::class.java), flags)
                session.commit(pi.intentSender)
            }
        } catch (e: Exception) {
            try {
                installer.abandonSession(id)
            } catch (_: Exception) {
            }
            UpdateStatus.sessionId = null
            throw e
        }
        return id
    }
}
