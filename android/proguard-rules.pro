-keep public class ru.mangapad.legacy.MainActivity { public *; protected *; }
-keepattributes Exceptions,InnerClasses,EnclosingMethod,Signature
-keepnames class ru.mangapad.legacy.**
# Keep API 10 references in their own class; API 9 must verify PageView safely.
-keep class ru.mangapad.legacy.PageRegion { *; }
-repackageclasses ru.mangapad.legacy.internal
# JCA creates the explicitly registered implementations through public constructors.
# Preserve SPI entry points while still allowing relocation away from Android's BC.
-keepclassmembers,allowobfuscation class org.bouncycastle.** extends java.security.SignatureSpi { public <init>(); protected *; }
-keepclassmembers,allowobfuscation class org.bouncycastle.** extends java.security.KeyFactorySpi { public <init>(); protected *; }
-keepclassmembers,allowobfuscation class org.bouncycastle.** extends java.security.AlgorithmParametersSpi { public <init>(); protected *; }
-keep,allowobfuscation class org.bouncycastle.jcajce.provider.asymmetric.x509.CertificateFactory { public *; }
-dontwarn javax.naming.**
-dontwarn javax.mail.**
-dontwarn java.lang.management.**
-dontwarn java.lang.instrument.**
-dontwarn java.awt.**
-dontwarn java.beans.**
-dontwarn org.bouncycastle.jsse.**
-dontwarn javax.microedition.khronos.**
-dontwarn org.xmlpull.v1.**
