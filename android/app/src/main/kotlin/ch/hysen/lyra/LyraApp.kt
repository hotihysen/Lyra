package ch.hysen.lyra

import android.app.Application
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Hält Abstürze fest, damit Lyra beim nächsten Start zeigen kann, was passiert ist. */
class LyraApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val sw = StringWriter()
                error.printStackTrace(PrintWriter(sw))
                val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.GERMANY).format(Date())
                File(filesDir, "last_crash.txt").writeText("Zeit: $time\nThread: ${thread.name}\n\n${sw.toString().take(6000)}")
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, error)
        }
    }

    companion object {
        fun takeCrash(app: Application): String? {
            val f = File(app.filesDir, "last_crash.txt")
            if (!f.exists()) return null
            val text = f.readText()
            f.delete()
            return text
        }
    }
}
