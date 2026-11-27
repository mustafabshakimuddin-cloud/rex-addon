# kotlinx.serialization: keep generated serializers.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class community.reel.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class community.reel.**$$serializer { *; }
-dontwarn org.slf4j.**
-keep class androidx.media3.decoder.ffmpeg.** { *; }
