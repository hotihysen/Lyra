package ch.hysen.lyra

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val worker = Executors.newFixedThreadPool(3)

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.hysen.lyra/update")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "canInstall" -> result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) packageManager.canRequestPackageInstalls() else true
                        )
                        "openInstallSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(
                                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            }
                            result.success(true)
                        }
                        "install" -> {
                            val file = File(call.argument<String>("path")!!)
                            Thread {
                                try {
                                    installWithSession(file)
                                    runOnUiThread { result.success(true) }
                                } catch (e: Exception) {
                                    // Ersatzweg: klassischer Installationsdialog
                                    runOnUiThread {
                                        try {
                                            openApk(file)
                                            result.success(true)
                                        } catch (e2: Exception) {
                                            result.error("update", e2.message ?: e.message, null)
                                        }
                                    }
                                }
                            }.start()
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("update", e.message, null)
                }
            }
    }

    /** Wie in Flimmer: Installation über eine PackageInstaller-Sitzung. Ab dem zweiten Update ohne Rückfrage (Android 12+). */
    private fun installWithSession(file: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        params.setSize(file.length())
        val id = installer.createSession(params)
        try {
            installer.openSession(id).use { session ->
                session.openWrite("lyra", 0, file.length()).use { out ->
                    file.inputStream().use { it.copyTo(out, 1 shl 16) }
                    session.fsync(out)
                }
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pi = PendingIntent.getBroadcast(this, 0, Intent(this, UpdateReceiver::class.java), flags)
                session.commit(pi.intentSender)
            }
        } catch (e: Exception) {
            installer.abandonSession(id)
            throw e
        }
    }

    private fun openApk(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        startActivity(intent)
    }
}
