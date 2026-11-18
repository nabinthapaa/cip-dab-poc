package com.reelbridge.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object RB {
    val Navy950 = Color(0xFF050817)
    val Navy900 = Color(0xFF070B1F)
    val Navy800 = Color(0xFF0E1433)
    val Navy700 = Color(0xFF161D45)
    val Navy600 = Color(0xFF232B5C)
    val Blue = Color(0xFF4F8BFF)
    val Purple = Color(0xFFA56BFF)
    val Cyan = Color(0xFF3DD6F5)
    val Success = Color(0xFF3DDC97)
    val Warning = Color(0xFFFFC857)
    val Error = Color(0xFFFF5C7A)
    val TextPrimary = Color(0xFFEFF2FF)
    val TextSecondary = Color(0xFFA3ABD6)

    val AccentGradient = Brush.linearGradient(listOf(Blue, Purple))
    val BackgroundGradient = Brush.verticalGradient(listOf(Navy800, Navy900, Navy950))
}

private val colors = darkColorScheme(
    primary = RB.Blue,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF1C3577),
    onPrimaryContainer = RB.TextPrimary,
    secondary = RB.Purple,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFF3A2470),
    onSecondaryContainer = RB.TextPrimary,
    tertiary = RB.Cyan,
    background = RB.Navy900,
    onBackground = RB.TextPrimary,
    surface = RB.Navy800,
    onSurface = RB.TextPrimary,
    surfaceVariant = RB.Navy700,
    onSurfaceVariant = RB.TextSecondary,
    surfaceContainer = RB.Navy800,
    surfaceContainerHigh = RB.Navy700,
    surfaceContainerHighest = RB.Navy600,
    outline = Color(0xFF39427A),
    outlineVariant = Color(0xFF262E60),
    error = RB.Error,
    onError = Color.White,
)

private val base = FontFamily.SansSerif
private val typography = Typography(
    displaySmall = TextStyle(fontFamily = base, fontWeight = FontWeight.Bold, fontSize = 34.sp, letterSpacing = (-0.5).sp),
    headlineMedium = TextStyle(fontFamily = base, fontWeight = FontWeight.Bold, fontSize = 26.sp, letterSpacing = (-0.25).sp),
    headlineSmall = TextStyle(fontFamily = base, fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    titleLarge = TextStyle(fontFamily = base, fontWeight = FontWeight.SemiBold, fontSize = 20.sp),
    titleMedium = TextStyle(fontFamily = base, fontWeight = FontWeight.SemiBold, fontSize = 16.sp),
    titleSmall = TextStyle(fontFamily = base, fontWeight = FontWeight.Medium, fontSize = 14.sp),
    bodyLarge = TextStyle(fontFamily = base, fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontFamily = base, fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontFamily = base, fontSize = 12.sp, lineHeight = 16.sp),
    labelLarge = TextStyle(fontFamily = base, fontWeight = FontWeight.SemiBold, fontSize = 15.sp),
    labelMedium = TextStyle(fontFamily = base, fontWeight = FontWeight.Medium, fontSize = 12.sp),
)

private val shapes = Shapes(
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(18.dp),
    large = RoundedCornerShape(26.dp),
)

@Composable
fun ReelBridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = colors, typography = typography, shapes = shapes, content = content)
}
