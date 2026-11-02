# kotlinx.serialization: keep generated serializers for the shared document model.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.aurum.core.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.aurum.core.**$$serializer { *; }
