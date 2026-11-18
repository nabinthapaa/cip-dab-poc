package com.reelbridge.app.ui

import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.reelbridge.app.ui.components.GradientBackground
import com.reelbridge.app.ui.connect.ConnectScreen
import com.reelbridge.app.ui.history.HistoryScreen
import com.reelbridge.app.ui.home.HomeScreen
import com.reelbridge.app.ui.publish.JobDetailScreen
import com.reelbridge.app.ui.settings.SettingsScreen
import com.reelbridge.app.ui.theme.RB

object Routes {
    const val HOME = "home"
    const val CONNECT = "connect"
    const val HISTORY = "history"
    const val SETTINGS = "settings"
    const val JOB = "job/{id}"
    fun job(id: String) = "job/$id"
}

private data class Tab(val route: String, val label: String, val icon: ImageVector)
private val tabs = listOf(
    Tab(Routes.HOME, "Home", Icons.Rounded.Home),
    Tab(Routes.HISTORY, "History", Icons.Rounded.History),
    Tab(Routes.SETTINGS, "Settings", Icons.Rounded.Settings),
)

@Composable
fun AppNav(vm: AppViewModel, startDestination: String? = null) {
    val nav = rememberNavController()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }
    LaunchedEffect(startDestination) {
        if (startDestination == Routes.HISTORY) nav.navigate(Routes.HISTORY) { launchSingleTop = true }
    }
    val backStack by nav.currentBackStackEntryAsState()
    val current = backStack?.destination?.route

    GradientBackground {
        Scaffold(
            containerColor = Color.Transparent,
            snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                if (current in tabs.map { it.route }) {
                    NavigationBar(containerColor = RB.Navy950.copy(alpha = 0.92f)) {
                        tabs.forEach { tab ->
                            NavigationBarItem(
                                selected = current == tab.route,
                                onClick = {
                                    nav.navigate(tab.route) {
                                        popUpTo(nav.graph.findStartDestination().id) { saveState = true }
                                        launchSingleTop = true
                                        restoreState = true
                                    }
                                },
                                icon = { Icon(tab.icon, tab.label) },
                                label = { Text(tab.label) },
                                colors = NavigationBarItemDefaults.colors(indicatorColor = MaterialTheme.colorScheme.primaryContainer),
                            )
                        }
                    }
                }
            },
        ) { padding ->
            NavHost(
                nav, startDestination = Routes.HOME, modifier = Modifier.padding(padding),
                enterTransition = { fadeIn() }, exitTransition = { fadeOut() },
            ) {
                composable(Routes.HOME) {
                    HomeScreen(vm, onConnect = { nav.navigate(Routes.CONNECT) }, onOpenJob = { nav.navigate(Routes.job(it)) },
                        onHistory = { nav.navigate(Routes.HISTORY) }, onSettings = { nav.navigate(Routes.SETTINGS) })
                }
                composable(Routes.CONNECT) { ConnectScreen(vm, onBack = { nav.popBackStack() }) }
                composable(Routes.HISTORY) { HistoryScreen(vm, onOpenJob = { nav.navigate(Routes.job(it)) }) }
                composable(Routes.SETTINGS) { SettingsScreen(vm, onConnect = { nav.navigate(Routes.CONNECT) }) }
                composable(Routes.JOB) { entry ->
                    JobDetailScreen(vm, entry.arguments?.getString("id").orEmpty(), onBack = { nav.popBackStack() })
                }
            }
        }
    }
}

/** Collects a StateFlow lifecycle-aware (small helper to keep screens short). */
@Composable
fun <T> kotlinx.coroutines.flow.StateFlow<T>.collect(): State<T> = collectAsStateWithLifecycle()
