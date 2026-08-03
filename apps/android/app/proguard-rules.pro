-keep class org.rustls.platformverifier.** { *; }
-keepclassmembers class org.rustls.platformverifier.** { *; }
-keep class com.example.havencat.HavenCatApplication {
    private native void initializePlatformVerifier(android.content.Context);
}
