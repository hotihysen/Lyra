package ch.hysen.lyra

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/** Zustand der optionalen PackageInstaller-Sitzung. */
object UpdateStatus {
    @Volatile var sessionId: Int? = null

    fun reset() {
        sessionId = null
    }
}

/** Rückmeldung des Android-Installers für die Sitzung (Diagnoseweg). */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -99)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val activity = MainActivity.current?.get()
        activity?.sendUpdateEvent("sessionStatus", mapOf("status" to status, "message" to message))

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val action: Intent = (if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }) ?: return
            // Über die sichtbare Activity öffnen; Starts aus dem Hintergrund blockiert Android sonst still.
            try {
                if (activity != null && !activity.isFinishing) {
                    activity.runOnUiThread { activity.startActivity(action) }
                } else {
                    context.startActivity(action.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
            } catch (e: Exception) {
                activity?.sendUpdateEvent("sessionStatus", mapOf("status" to 1, "message" to "Bestätigung konnte nicht geöffnet werden: ${e.message}"))
            }
        } else if (status != -99) {
            UpdateStatus.sessionId = null
        }
    }
}
