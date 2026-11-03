// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
package cn.aquantum.aquantum_reader.plugins

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.io.ByteArrayInputStream

class DocumentWebViewFactory(private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        DocumentWebView(context, messenger, viewId)
}

@SuppressLint("SetJavaScriptEnabled")
private class DocumentWebView(context: Context, messenger: BinaryMessenger, id: Int) : PlatformView {
    private val web = WebView(context)
    private val channel = MethodChannel(messenger, "cn.aquantum/document/$id")
    private val main = Handler(Looper.getMainLooper())
    private var closed = false
    private val origin = "aq.local"
    private val entry = "https://$origin/reader/index.html"
    init {
        web.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        web.addJavascriptInterface(object {
            @JavascriptInterface fun post(text: String) {
                main.post { if (!closed) channel.invokeMethod("message", text) }
            }
        }, "AqNative")
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                val uri = request.url
                val path = uri.path.orEmpty().removePrefix("/")
                // Every network request is answered here. Only shipped engine
                // assets can be read; user documents never supply a disk path.
                if (uri.scheme != "https" || uri.host != origin || uri.port != -1 ||
                    request.method != "GET" || path.split('/').any { it == ".." || it == "." } ||
                    !(path.startsWith("reader/") || path.startsWith("foliate/"))) return denied()
                return try {
                    val mime = when (path.substringAfterLast('.')) {
                        "js" -> "text/javascript"
                        "html" -> "text/html"
                        "css" -> "text/css"
                        else -> "text/plain"
                    }
                    WebResourceResponse(mime, "UTF-8", context.assets.open("flutter_assets/web/$path"))
                } catch (_: Exception) { denied() }
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.isForMainFrame || !allowedFrame(request.url)
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                if (url != entry && url != "about:blank") web.stopLoading()
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: android.webkit.WebResourceError) {
                if (request.isForMainFrame) sendError(error.description.toString())
            }
        }
        channel.setMethodCallHandler { call, result ->
            if (closed && call.method != "close") { result.error("closed", "文档引擎已关闭", null); return@setMethodCallHandler }
            when (call.method) {
                "load" -> { web.loadUrl(entry); result.success(null) }
                "post" -> {
                    val message = call.arguments as? String
                    if (message == null) result.error("message", "消息无效", null)
                    else web.evaluateJavascript("globalThis.AqReader?.receive(${JSONObject.quote(message)})") { result.success(null) }
                }
                "close" -> { close(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    private fun allowedFrame(uri: Uri): Boolean = uri.scheme == "blob" ||
        (uri.scheme == "about" && uri.toString() == "about:blank")
    private fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    private fun sendError(error: String) {
        channel.invokeMethod("message", JSONObject().put("event", "load-error")
            .put("detail", JSONObject().put("error", error)).toString())
    }
    private fun close() {
        if (closed) return
        closed = true
        web.stopLoading()
        web.removeJavascriptInterface("AqNative")
        web.loadUrl("about:blank")
        web.destroy()
    }
    override fun getView() = web
    override fun dispose() { close(); channel.setMethodCallHandler(null) }
}
