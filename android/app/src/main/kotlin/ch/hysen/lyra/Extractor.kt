package ch.hysen.lyra

import dev.maxrave.pipepipe.extractor.NewPipe
import dev.maxrave.pipepipe.extractor.ServiceList
import dev.maxrave.pipepipe.extractor.downloader.CancellableCall
import dev.maxrave.pipepipe.extractor.downloader.Downloader
import dev.maxrave.pipepipe.extractor.downloader.Request
import dev.maxrave.pipepipe.extractor.downloader.Response
import dev.maxrave.pipepipe.extractor.exceptions.ReCaptchaException
import dev.maxrave.pipepipe.extractor.services.youtube.YoutubeApiDecoder
import dev.maxrave.pipepipe.extractor.stream.StreamInfo
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit
import org.schabi.newpipe.extractor.NewPipe as BraveNewPipe
import org.schabi.newpipe.extractor.ServiceList as BraveServiceList
import org.schabi.newpipe.extractor.downloader.Downloader as BraveDownloader
import org.schabi.newpipe.extractor.downloader.Request as BraveRequest
import org.schabi.newpipe.extractor.downloader.Response as BraveResponse
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException as BraveReCaptcha
import org.schabi.newpipe.extractor.stream.StreamInfo as BraveStreamInfo

/**
 * YouTube-Audio wie in SimpMusic: PipePipe-Extraktor (Signaturen werden über api.pipepipe.dev gelöst),
 * danach BravePipe als zweiter, unabhängiger Extraktor.
 */
object Extractor {
    const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    /** Audio-itags in Reihenfolge der Bevorzugung: AAC 128k (läuft überall), dann Opus. */
    private val AUDIO_ITAGS = listOf(140, 251, 250, 249, 139)

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    @Volatile private var ready = false

    @Synchronized
    fun init() {
        if (ready) return
        NewPipe.init(PipeDownloader(client))
        BraveNewPipe.init(BravePipeDownloader(client))
        ready = true
    }

    data class Audio(val url: String, val itag: Int, val source: String)

    /** Liefert die beste spielbare Audio-URL oder wirft mit allen Fehlergründen. */
    fun audio(videoId: String): Audio {
        init()
        val errors = mutableListOf<String>()

        // Stufe 1: PipePipe, Signaturen vom Server lösen lassen
        try {
            YoutubeApiDecoder.setLocalDecoder(null)
            val info = StreamInfo.getInfo(ServiceList.YouTube, "https://music.youtube.com/watch?v=$videoId")
            val list = info.audioStreams.mapNotNull { s -> s.itagItem?.id?.let { it to s.content } }
            pick(list)?.let { return Audio(it.second, it.first, "PipePipe") }
            errors += "PipePipe: kein spielbarer Stream (${list.map { it.first }})"
        } catch (t: Throwable) {
            errors += "PipePipe: ${t.javaClass.simpleName} ${t.message?.take(80)}"
        }

        // Stufe 2: BravePipe
        try {
            val info = BraveStreamInfo.getInfo(BraveServiceList.YouTube, "https://www.youtube.com/watch?v=$videoId")
            val list = info.audioStreams.mapNotNull { s -> s.itagItem?.id?.let { it to s.content } }
            pick(list)?.let { return Audio(it.second, it.first, "BravePipe") }
            errors += "BravePipe: kein spielbarer Stream (${list.map { it.first }})"
        } catch (t: Throwable) {
            errors += "BravePipe: ${t.javaClass.simpleName} ${t.message?.take(80)}"
        }
        throw IOException(errors.joinToString("\n"))
    }

    /** Bevorzugten itag wählen und prüfen, ob der Server ihn wirklich ausliefert. */
    private fun pick(list: List<Pair<Int, String>>): Pair<Int, String>? {
        val sorted = list.sortedBy { AUDIO_ITAGS.indexOf(it.first).let { i -> if (i < 0) 99 else i } }
        for (c in sorted.take(3)) {
            if (check(c.second)) return c
        }
        return null
    }

    private fun check(url: String): Boolean = runCatching {
        val req = okhttp3.Request.Builder().url(url)
            .header("User-Agent", USER_AGENT)
            .header("Range", "bytes=0-1023")
            .build()
        client.newCall(req).execute().use { it.code in 200..299 }
    }.getOrDefault(false)

    // ---------- Netzwerk-Adapter für die beiden Extraktoren ----------

    private fun build(method: String, url: String, body: ByteArray?, headers: Map<String, List<String>>): okhttp3.Request {
        val b = okhttp3.Request.Builder()
            .method(method, body?.toRequestBody())
            .url(url)
            .addHeader("User-Agent", USER_AGENT)
        headers.forEach { (name, values) ->
            if (values.size > 1) {
                b.removeHeader(name)
                values.forEach { b.addHeader(name, it) }
            } else if (values.size == 1) {
                b.header(name, values[0])
            }
        }
        return b.build()
    }

    class PipeDownloader(private val client: OkHttpClient) : Downloader() {
        @Throws(IOException::class, ReCaptchaException::class)
        override fun execute(request: Request): Response {
            val r = client.newCall(build(request.httpMethod(), request.url(), request.dataToSend(), request.headers())).execute()
            if (r.code == 429) {
                r.close()
                throw ReCaptchaException("reCaptcha Challenge requested", request.url())
            }
            return r.toPipe()
        }

        @Throws(IOException::class, ReCaptchaException::class)
        override fun executeAsync(request: Request, callback: AsyncCallback?): CancellableCall {
            val call = client.newCall(build(request.httpMethod(), request.url(), request.dataToSend(), request.headers()))
            val cancellable = CancellableCall(call)
            call.enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: IOException) {
                    cancellable.setFinished()
                    callback?.onError(e)
                }

                override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                    try {
                        if (response.code == 429) {
                            response.close()
                            callback?.onError(ReCaptchaException("reCaptcha Challenge requested", request.url()))
                            return
                        }
                        callback?.onSuccess(response.toPipe())
                    } catch (e: Exception) {
                        callback?.onError(e)
                    } finally {
                        cancellable.setFinished()
                    }
                }
            })
            return cancellable
        }

        private fun okhttp3.Response.toPipe(): Response {
            val raw = body?.bytes() ?: ByteArray(0)
            return Response(code, message, headers.toMultimap(), raw.toString(Charsets.UTF_8), raw, request.url.toString())
        }
    }

    class BravePipeDownloader(private val client: OkHttpClient) : BraveDownloader() {
        @Throws(IOException::class, BraveReCaptcha::class)
        override fun execute(request: BraveRequest): BraveResponse {
            val r = client.newCall(build(request.httpMethod(), request.url(), request.dataToSend(), request.headers())).execute()
            if (r.code == 429) {
                r.close()
                throw BraveReCaptcha("reCaptcha Challenge requested", request.url())
            }
            val body = r.body?.string()
            return BraveResponse(r.code, r.message, r.headers.toMultimap(), body, r.request.url.toString())
        }
    }
}
