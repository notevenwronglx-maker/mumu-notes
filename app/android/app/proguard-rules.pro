# Keep Flutter wrapper, plugins (including shared_preferences Pigeon registrars), and Kotlin coroutines Continuation
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class kotlin.Metadata { *; }
-keep class kotlin.coroutines.** { *; }
-keep interface kotlin.coroutines.Continuation { *; }
-keep class kotlinx.coroutines.** { *; }

# 保持 PalmGuard 宿主桥接与模型类不被 R8 混淆或移除
-keep class com.mumunotes.core.touch.PalmGuardFlutterHostHelper { *; }
-keep class com.mumunotes.core.touch.PalmGuardTouchBridge { *; }
-keep class com.mumunotes.core.touch.model.** { *; }
-keep class com.mumunotes.** { *; }

-dontwarn io.flutter.embedding.**
-dontwarn kotlin.**
-dontwarn kotlinx.**
