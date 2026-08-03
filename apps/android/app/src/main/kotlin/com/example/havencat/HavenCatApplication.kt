package com.example.havencat

import android.app.Application
import android.content.Context

class HavenCatApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        System.loadLibrary("app_rust")
        initializePlatformVerifier(applicationContext)
    }

    private external fun initializePlatformVerifier(context: Context)
}
