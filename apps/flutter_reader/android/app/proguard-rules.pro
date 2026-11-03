# shared_preferences_android 2.5.0 invokes Kotlin suspend registrars from JNI.
# @Keep preserves the registrar, but R8 otherwise renames Continuation in its
# method descriptors, so GetMethodID cannot find getAll/setString at runtime.
# Preserve only these native entry contracts and their descriptor types.
-keep,includedescriptorclasses class io.flutter.plugins.sharedpreferences.**ApiRegistrar { *; }
-keep,includedescriptorclasses interface kotlin.coroutines.Continuation { *; }
# jni 1.1.0/lib/src/kotlin.dart resolves these runtime helpers by class name.
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }

# The document WebView calls only the annotated message transport through JNI.
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }
