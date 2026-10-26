package ch.hysen.lyra

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/** Letzte Rückmeldung des Android-Installers, damit die App reagieren kann. */
object UpdateStatus {
    const val NONE = -99
    @Volatile var status: Int = NONE
    @Volatile var message: String? = null

    fun reset() {
        status = NONE
        message = null
    }
}

/** Rückmeldung des Android-Installers (gleiches Vorgehen wie in Flimmer). */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, UpdateStatus.NONE)
        UpdateStatus.status = status
        UpdateStatus.message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val action: Intent = (if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }) ?: return
            // Über die sichtbare Activity öffnen: Starts aus dem Hintergrund blockiert Android sonst still.
            val activity = MainActivity.current?.get()
            if (activity != null && !activity.isFinishing) {
                activity.runOnUiThread {
                    try {
                        activity.startActivity(action)
                    } catch (e: Exception) {
                        UpdateStatus.message = e.message
                    }
                }
            } else {
                action.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(action)
                } catch (e: Exception) {
                    UpdateStatus.message = e.message
                }
            }
        }
    }
}
