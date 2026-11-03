// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
package cn.aquantum.aquantum_reader.plugins

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract as Docs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import org.json.JSONObject

/** Platform I/O only. Selection grants never become broad storage permissions.
 * Copies and failed publications remain in no_backup; no user data is swept. */
class AndroidDocuments(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "cn.aquantum/documents")
    private val root = File(activity.noBackupFilesDir, "document-io").apply { mkdirs() }.canonicalFile
    private var pending: MethodChannel.Result? = null
    private var copying = false
    private val request = 5005
    private val trees = java.util.concurrent.ConcurrentHashMap<String, Uri>()
    init { channel.setMethodCallHandler(::handle) }

    private fun work(result: MethodChannel.Result, action: () -> Any?) {
        Thread {
            try {
                val value = action()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("document_io", "${e.message}；暂存保留。可重新选择来源，或从存储维护继续保存已生成文件。", null) }
            }
        }.start()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "importTree", "outputTree" -> {
                if (pending != null) { result.error("busy", "文件选择正在进行", null); return }
                pending = result
                copying = call.method == "importTree"
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }, request)
                } catch (e: Exception) { pending = null; result.error("picker", e.message, null) }
            }
            "publish" -> work(result) {
                val job = call.argument<String>("job") ?: error("缺少保存任务")
                require(runCatching { UUID.fromString(job).toString() == job }.getOrDefault(false)) { "保存任务无效" }
                val name = safeName(call.argument<String>("name") ?: "")
                val tree = trees[job] ?: error("目录授权已失效，请重新选择保存目录")
                val source = File(File(root, "outputs/$job"), name)
                require(source.isFile && source.canonicalFile == source.absoluteFile) { "保存暂存不存在或路径无效" }
                publish(source, tree)
            }
            "pending" -> work(result) {
                File(root, "outputs").listFiles().orEmpty().flatMap { job ->
                    job.listFiles().orEmpty().filter {
                        it.isFile && !it.name.endsWith(".json") && !it.name.endsWith(".part") &&
                            !File(job, "${it.name}.published.json").exists()
                    }.map { mapOf("path" to it.canonicalPath, "name" to it.name, "bytes" to it.length()) }
                }
            }
            "retained" -> work(result) {
                var bytes = 0L
                var files = 0L
                val base = root.path + File.separator
                root.walkTopDown().onEnter { it == root || it.canonicalPath.startsWith(base) }
                    .onFail { _, error -> throw error }
                    .filter { it.isFile && it.canonicalPath.startsWith(base) }
                    .forEach { bytes += it.length(); files++ }
                mapOf("bytes" to bytes, "files" to files)
            }
            "retry" -> work(result) {
                val job = call.argument<String>("job") ?: error("缺少保存任务")
                require(runCatching { UUID.fromString(job).toString() == job }.getOrDefault(false)) { "保存任务无效" }
                val source = File(call.argument<String>("source") ?: "").canonicalFile
                val base = File(root, "outputs").canonicalPath + File.separator
                require(source.path.startsWith(base) && source.isFile && !source.name.endsWith(".json") && !source.name.endsWith(".part")) { "保存来源无效" }
                val tree = trees[job] ?: error("请重新选择保存目录")
                val destination = File(File(root, "outputs/$job"), "重试-${System.currentTimeMillis()}-${source.name}")
                val partial = File(destination.parentFile, "${destination.name}.part")
                source.copyTo(partial, overwrite = false)
                require(partial.renameTo(destination)) { "无法发布完整的保存暂存" }
                val uri = publish(destination, tree)
                // The old bytes remain. A receipt stops offering the same retry.
                File(source.parentFile, "${source.name}.published.json").writeText(JSONObject().put("reissued", uri).toString())
                uri
            }
            else -> result.notImplemented()
        }
    }

    fun onResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != request) return false
        val result = pending ?: return true
        pending = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) { result.success(null); return true }
        val isCopy = copying
        work(result) {
            val id = UUID.randomUUID().toString()
            if (isCopy) {
                val document = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
                val title = activity.contentResolver.query(document, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                    require(cursor.moveToFirst()) { "无法读取文件夹名称" }; safeName(cursor.getString(0))
                } ?: error("无法读取文件夹名称")
                val destination = File(root, "inputs/$id/$title").apply { check(mkdirs()) }
                var count = 0
                var bytes = 0L
                val visited = mutableSetOf<String>()
                fun copyDirectory(document: Uri, target: File, depth: Int) {
                    require(depth <= 32 && visited.add(Docs.getDocumentId(document))) { "文件夹层级过深或循环引用" }
                    val children = Docs.buildChildDocumentsUriUsingTree(tree, Docs.getDocumentId(document))
                    val names = mutableSetOf<String>()
                    activity.contentResolver.query(children, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                        while (cursor.moveToNext()) {
                            require(++count <= 10000) { "文件夹超过 10000 项" }
                            val name = safeName(cursor.getString(1))
                            require(names.add(name.lowercase(Locale.ROOT))) { "文件夹含重复或大小写冲突名称" }
                            val child = Docs.buildDocumentUriUsingTree(tree, cursor.getString(0))
                            val output = File(target, name)
                            if (cursor.getString(2) == Docs.Document.MIME_TYPE_DIR) {
                                check(output.mkdir()); copyDirectory(child, output, depth + 1)
                            } else {
                                check(output.createNewFile())
                                activity.contentResolver.openInputStream(child)?.use { input ->
                                    output.outputStream().use { stream ->
                                        val buffer = ByteArray(65536)
                                        while (true) {
                                            val n = input.read(buffer); if (n < 0) break
                                            bytes += n; require(bytes <= 512L * 1024 * 1024) { "文件夹超过 512 MiB" }
                                            stream.write(buffer, 0, n)
                                        }
                                    }
                                } ?: error("无法读取所选文件")
                            }
                        }
                    } ?: error("无法读取所选文件夹")
                }
                copyDirectory(document, destination, 0)
                destination.canonicalPath
            } else {
                val directory = File(root, "outputs/$id").apply { check(mkdirs()) }
                trees[id] = tree
                mapOf("job" to id, "path" to directory.canonicalPath)
            }
        }
        return true
    }

    private fun safeName(value: String): String {
        require(value.isNotBlank() && value != "." && value != ".." &&
            value.none { it == '/' || it == '\\' || it == ':' || it.code < 32 }) { "文件名不安全" }
        return value
    }

    private fun digest(input: java.io.InputStream): String = input.use { stream ->
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(65536)
        while (true) { val n = stream.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) }
        hash.digest().joinToString("") { "%02x".format(it) }
    }

    private fun publish(source: File, tree: Uri): String {
        val resolver = activity.contentResolver
        val parent = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
        val children = Docs.buildChildDocumentsUriUsingTree(tree, Docs.getTreeDocumentId(tree))
        resolver.query(children, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) require(!cursor.getString(0).equals(source.name, ignoreCase = true)) { "目标已存在，不会覆盖；请另选目录或文件名" }
        } ?: error("无法检查保存目录")
        val sha = digest(source.inputStream())
        val mime = when (source.extension.lowercase(Locale.ROOT)) {
            "cbz" -> "application/vnd.comicbook+zip"
            "zip" -> "application/zip"
            "aqb" -> "application/x-aquantum-backup"
            else -> error("不支持的保存类型")
        }
        val uri = Docs.createDocument(resolver, parent, mime, safeName(source.name)) ?: error("无法创建新文件")
        resolver.query(uri, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            require(cursor.moveToFirst() && cursor.getString(0) == source.name) { "保存服务更改了文件名；新建文件和本地副本已保留，请另选目录" }
        } ?: error("无法核对新文件名")
        // Record the exact new URI before writing. Failures and partial targets stay.
        File(source.parentFile, "${source.name}.intent.json").writeText(JSONObject().put("uri", uri.toString()).put("sha256", sha).toString())
        resolver.openOutputStream(uri, "w")?.use { output -> source.inputStream().use { it.copyTo(output, 65536) } } ?: error("无法写入新文件")
        val actual = resolver.openInputStream(uri)?.let { digest(it) } ?: error("无法重新读取保存文件")
        require(actual == sha && digest(source.inputStream()) == sha) { "保存后校验不一致，源页保留" }
        File(source.parentFile, "${source.name}.published.json").writeText(JSONObject().put("uri", uri.toString()).put("sha256", sha).put("bytes", source.length()).toString())
        return uri.toString()
    }
}
