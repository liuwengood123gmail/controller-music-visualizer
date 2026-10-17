# JNI：C 层按「包名 + 类名 + 方法名」找 NativeCore 的 external 方法，不能混淆
-keep class app.cmv.engine.android.NativeCore { *; }
