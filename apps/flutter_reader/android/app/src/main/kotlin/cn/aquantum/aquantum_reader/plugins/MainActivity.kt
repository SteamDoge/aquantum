// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
package cn.aquantum.aquantum_reader.plugins

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.Intent

class MainActivity : FlutterActivity() {
    private lateinit var documents: AndroidDocuments
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        documents = AndroidDocuments(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "cn.aquantum/document",
            DocumentWebViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::documents.isInitialized && documents.onResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
