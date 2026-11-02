package com.aurum.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.aurum.app.ui.AppViewModel
import com.aurum.app.ui.AurumApp
import com.aurum.app.ui.theme.AurumTheme

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) model.handleLink(intent?.data)
        setContent {
            AurumTheme(model.container.brand) {
                AurumApp(model)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        model.handleLink(intent.data)
    }
}
