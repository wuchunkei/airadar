package com.airadar.app.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import com.airadar.app.data.FlightStatus

@Composable
@ReadOnlyComposable
fun FlightStatus.statusColor(): Color {
    val dark = isDarkTheme()
    return when (this) {
        FlightStatus.ON_TIME,
        FlightStatus.LANDED -> if (dark) Color(0xFF5BD9A8) else Color(0xFF067A54)

        FlightStatus.DELAYED -> if (dark) Color(0xFFFFB067) else Color(0xFFB4560B)

        FlightStatus.CANCELLED,
        FlightStatus.DIVERTED -> if (dark) Color(0xFFFF8A80) else Color(0xFFB3261E)

        FlightStatus.BOARDING,
        FlightStatus.DEPARTED,
        FlightStatus.IN_FLIGHT -> if (dark) Color(0xFF7FB8FF) else Color(0xFF0B5CC4)

        FlightStatus.SCHEDULED,
        FlightStatus.COMPLETED -> if (dark) Color(0xFFB0ADBA) else Color(0xFF5F5C66)
    }
}
