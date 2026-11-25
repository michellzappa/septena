# Septena Android R8 / ProGuard rules.
#
# Keep JNA and the generated UniFFI shared-core bindings intact so native Rust
# calls and @Structure.FieldOrder reflection survive full R8 optimization.

-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,SourceFile,LineNumberTable

# JNA + UniFFI generated bindings (app.septena.sharedcore)
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class * extends com.sun.jna.Structure { *; }
-keep class * extends com.sun.jna.Callback { *; }
-keep class * implements com.sun.jna.Library { *; }
-keep class app.septena.sharedcore.** { *; }

# JNA's JVM desktop code paths reference JDK packages absent on Android.
-dontwarn java.awt.**
-dontwarn javax.swing.**
-dontwarn java.lang.management.**
-dontwarn javax.naming.**
-dontwarn javax.xml.**
-dontwarn sun.misc.**
-dontwarn com.sun.jna.**
-dontwarn org.codehaus.mojo.animal_sniffer.**

# Broadcast receivers and widgets instantiated by the system.
-keep class app.septena.android.reminders.** { *; }
-keep class app.septena.android.widgets.** { *; }
